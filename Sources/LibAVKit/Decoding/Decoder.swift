import CFFmpeg
import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

public enum DecoderError: Error, LocalizedError {
    case openFailed(String)
    case streamInfoNotFound
    case audioStreamNotFound
    case codecNotFound
    case codecOpenFailed
    case decodeFailed
    case resamplerfailed
    case endOfFile
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case let .openFailed(path):
            "Failed to open audio file: \(path)"
        case .streamInfoNotFound:
            "Could not find stream information"
        case .audioStreamNotFound:
            "No audio stream found"
        case .codecNotFound:
            "Audio codec not found"
        case .codecOpenFailed:
            "Failed to open audio codec"
        case .decodeFailed:
            "Audio decoding failed"
        case .resamplerfailed:
            "Failed to initialize audio resampler"
        case .endOfFile:
            "End of file reached"
        case .notConfigured:
            "Decoder not configured"
        }
    }
}

// FFmpeg constants that can't be imported as macros
private let AV_NOPTS_VALUE: Int64 = .init(bitPattern: 0x8000_0000_0000_0000)
private let AVERROR_EOF_VALUE: Int32 = -541_478_725

public final class Decoder: @unchecked Sendable {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var audioStreamIndex: Int32 = -1

    // Default output format (can be overridden via configure())
    private var outputSampleRate: Int32 = 44100
    private var outputChannels: Int32 = 2
    private var outputSampleFormat: AVSampleFormat = AV_SAMPLE_FMT_FLT

    /// How decoded frames are converted to the output format.
    private enum ConversionMode {
        case passthrough      // Source is already FLTP — zero-copy pointer forwarding
        case fastS32PToFloat  // Source is S32P (planar) — vDSP SIMD, stride 1
        case fastS16PToFloat  // Source is S16P (planar) — vDSP SIMD, stride 1
        case fastS32ToFloat   // Source is S32 (interleaved) — vDSP SIMD, stride N
        case fastS16ToFloat   // Source is S16 (interleaved) — vDSP SIMD, stride N
        case resample         // Everything else — FFmpeg swr generic resampler
    }
    private var conversionMode: ConversionMode = .resample

    /// Pre-allocated resample output buffers (one per channel), reused across frames
    private var resampleBuffers: [UnsafeMutablePointer<Float>] = []
    private var resampleBufferCapacity: Int = 0

    /// Cached channel pointer array — mutated in-place to avoid per-frame allocation.
    /// COW is safe: DecodedFrame is dropped before next mutation (refcount 1 at mutation time).
    private var cachedChannelPointers: [UnsafePointer<Float>] = []

    // Source format information (populated after open)
    public private(set) var duration: TimeInterval = 0
    public private(set) var sampleRate: Int = 0
    public private(set) var channels: Int = 0
    public private(set) var bitrate: Int = 0
    public private(set) var codecName: String = ""
    public private(set) var bitsPerSample: Int = 0

    /// The source audio format detected from the file
    public var sourceFormat: AudioOutputFormat? {
        guard sampleRate > 0, channels > 0 else { return nil }
        return AudioOutputFormat(
            sampleRate: Double(sampleRate),
            channelCount: channels,
            sampleFormat: detectSourceSampleFormat(),
            isInterleaved: false
        )
    }

    /// The configured output format
    public var configuredOutputFormat: AudioOutputFormat {
        AudioOutputFormat(
            sampleRate: Double(outputSampleRate),
            channelCount: Int(outputChannels),
            sampleFormat: avSampleFormatToAudioSampleFormat(outputSampleFormat),
            isInterleaved: false
        )
    }

    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?

    /// True once the demuxer has hit EOF and the codec has been switched to
    /// drain mode (null packet sent). Remaining buffered frames are then pulled
    /// from the codec until it reports EOF. Reset by `seek(to:)` and `close()`.
    private var isDraining = false

    public init() {
        packet = av_packet_alloc()
        frame = av_frame_alloc()
    }

    deinit {
        close()
        if packet != nil {
            av_packet_free(&self.packet)
        }
        if frame != nil {
            av_frame_free(&self.frame)
        }
    }

    /// Configure the decoder output format before calling open()
    public func configure(outputFormat: AudioOutputFormat) {
        outputSampleRate = Int32(outputFormat.sampleRate)
        outputChannels = Int32(outputFormat.channelCount)
        outputSampleFormat = audioSampleFormatToAVSampleFormat(outputFormat.sampleFormat)
    }

    /// Reconfigure output format and rebuild resampler (call after open())
    /// This allows changing the output format without re-opening the file
    public func reconfigure(outputFormat: AudioOutputFormat) throws {
        guard codecContext != nil else {
            throw DecoderError.notConfigured
        }

        // Update output format
        outputSampleRate = Int32(outputFormat.sampleRate)
        outputChannels = Int32(outputFormat.channelCount)
        outputSampleFormat = audioSampleFormatToAVSampleFormat(outputFormat.sampleFormat)

        // Rebuild resampler with new settings
        if swrContext != nil {
            swr_free(&swrContext)
        }
        try setupResampler()
    }

    public func open(url: URL) throws {
        close()

        let path = url.path
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        guard avformat_open_input(&fmtCtx, path, nil, nil) == 0 else {
            throw DecoderError.openFailed(path)
        }
        formatContext = fmtCtx

        try setupAfterOpen()
    }

    /// Open a raw path with an optional format hint. Use `"pipe:0"` with a
    /// format name (e.g. `"flac"`) to read from STDIN.
    public func open(path: String, inputFormat: String? = nil) throws {
        close()

        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        let fmt: UnsafePointer<AVInputFormat>? = inputFormat.flatMap { av_find_input_format($0) }

        guard avformat_open_input(&fmtCtx, path, fmt, nil) == 0 else {
            throw DecoderError.openFailed(path)
        }
        formatContext = fmtCtx

        try setupAfterOpen()
    }

    private func setupAfterOpen() throws {
        guard avformat_find_stream_info(formatContext, nil) >= 0 else {
            throw DecoderError.streamInfoNotFound
        }

        // Find audio stream
        for i in 0 ..< Int32(formatContext!.pointee.nb_streams) {
            let stream = formatContext!.pointee.streams[Int(i)]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                audioStreamIndex = i
                break
            }
        }

        guard audioStreamIndex >= 0 else {
            throw DecoderError.audioStreamNotFound
        }

        let stream = formatContext!.pointee.streams[Int(audioStreamIndex)]!
        let codecPar = stream.pointee.codecpar!

        // Find decoder
        guard let codec = avcodec_find_decoder(codecPar.pointee.codec_id) else {
            throw DecoderError.codecNotFound
        }

        codecContext = avcodec_alloc_context3(codec)
        avcodec_parameters_to_context(codecContext, codecPar)

        guard avcodec_open2(codecContext, codec, nil) == 0 else {
            throw DecoderError.codecOpenFailed
        }

        // Extract metadata
        let timeBase = stream.pointee.time_base
        if stream.pointee.duration != AV_NOPTS_VALUE {
            duration = Double(stream.pointee.duration) * av_q2d(timeBase)
        } else if formatContext!.pointee.duration != AV_NOPTS_VALUE {
            duration = Double(formatContext!.pointee.duration) / Double(AV_TIME_BASE)
        }

        sampleRate = Int(codecContext!.pointee.sample_rate)
        channels = Int(codecContext!.pointee.ch_layout.nb_channels)
        bitrate = Int(codecPar.pointee.bit_rate)
        codecName = String(cString: avcodec_get_name(codecPar.pointee.codec_id))
        bitsPerSample = Int(codecPar.pointee.bits_per_raw_sample)
        if bitsPerSample == 0 {
            bitsPerSample = Int(av_get_bytes_per_sample(codecContext!.pointee.sample_fmt) * 8)
        }

        // Setup resampler (may be passthrough if formats match)
        try setupResampler()
    }

    private func setupResampler() throws {
        guard let ctx = codecContext else { return }

        let sourceFmt = ctx.pointee.sample_fmt
        let sourceRate = ctx.pointee.sample_rate
        let sourceChannels = ctx.pointee.ch_layout.nb_channels

        // Fast paths when sample rate and channel count already match output
        if sourceRate == outputSampleRate && sourceChannels == outputChannels {
            // Passthrough: source is already float32 planar
            if sourceFmt == AV_SAMPLE_FMT_FLTP || sourceFmt == outputSampleFormat {
                conversionMode = .passthrough
                swrContext = nil
                return
            }

            // vDSP SIMD conversion: integer → float32 planar (no swr needed)
            #if canImport(Accelerate)
            if outputSampleFormat == AV_SAMPLE_FMT_FLTP {
                switch sourceFmt {
                case AV_SAMPLE_FMT_S32P:
                    conversionMode = .fastS32PToFloat; swrContext = nil; return
                case AV_SAMPLE_FMT_S16P:
                    conversionMode = .fastS16PToFloat; swrContext = nil; return
                case AV_SAMPLE_FMT_S32:
                    conversionMode = .fastS32ToFloat; swrContext = nil; return
                case AV_SAMPLE_FMT_S16:
                    conversionMode = .fastS16ToFloat; swrContext = nil; return
                default:
                    break
                }
            }
            #endif
        }

        // Fallback: generic FFmpeg resampler
        conversionMode = .resample

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, outputChannels)

        var swrCtx: OpaquePointer?
        let result = swr_alloc_set_opts2(
            &swrCtx,
            &outLayout,
            outputSampleFormat,
            outputSampleRate,
            &ctx.pointee.ch_layout,
            ctx.pointee.sample_fmt,
            ctx.pointee.sample_rate,
            0,
            nil
        )

        guard result >= 0, let swr = swrCtx else {
            throw DecoderError.resamplerfailed
        }

        guard swr_init(swr) >= 0 else {
            swr_free(&swrCtx)
            throw DecoderError.resamplerfailed
        }

        swrContext = swr
    }

    /// Ensure pre-allocated resample buffers have the required capacity.
    /// Uses amortized doubling — only reallocates when frame size exceeds current capacity.
    private func ensureResampleBuffers(channelCount: Int, minCapacity: Int) {
        if resampleBuffers.count == channelCount && resampleBufferCapacity >= minCapacity {
            return
        }
        // Free old buffers
        for buf in resampleBuffers { buf.deallocate() }
        // Allocate with headroom to avoid frequent reallocs
        let capacity = max(minCapacity, resampleBufferCapacity * 2)
        resampleBuffers = (0..<channelCount).map { _ in .allocate(capacity: capacity) }
        resampleBufferCapacity = capacity
    }

    /// Decode the next frame and pass raw audio data to the handler via ``DecodedFrame``.
    /// The frame's pointers are only valid for the duration of the callback.
    ///
    /// When the demuxer reaches EOF, the codec is switched to drain mode so frames
    /// it still buffers internally (codec delay — MP3, AAC, etc.) are delivered
    /// before ``DecoderError/endOfFile`` is thrown. Without draining, the tail of
    /// every file would be silently dropped.
    ///
    /// Throws ``DecoderError/endOfFile`` when no more data is available.
    public func decodeNextFrame(handler: (DecodedFrame) throws -> Void) throws {
        guard let formatContext,
              let codecContext,
              let packet,
              let frame else {
            throw DecoderError.decodeFailed
        }

        while true {
            if !isDraining {
                let readResult = av_read_frame(formatContext, packet)
                if readResult == AVERROR_EOF_VALUE || readResult == -EAGAIN {
                    // Demuxer exhausted — switch the codec to drain mode and fall
                    // through to receive the frames it still holds
                    isDraining = true
                    avcodec_send_packet(codecContext, nil)
                } else {
                    defer { av_packet_unref(packet) }

                    guard packet.pointee.stream_index == audioStreamIndex else {
                        continue
                    }

                    let sendResult = avcodec_send_packet(codecContext, packet)
                    if sendResult < 0 { continue }
                }
            }

            while true {
                let receiveResult = avcodec_receive_frame(codecContext, frame)
                if receiveResult == AVERROR_EOF_VALUE {
                    throw DecoderError.endOfFile
                }
                if receiveResult == -EAGAIN {
                    break
                }
                if receiveResult < 0 {
                    throw DecoderError.decodeFailed
                }

                defer { av_frame_unref(frame) }

                if let decoded = convertFrame(frame) {
                    try handler(decoded)
                    return
                }
            }

            // EAGAIN while draining shouldn't occur; treat as EOF to avoid spinning
            if isDraining {
                throw DecoderError.endOfFile
            }
        }
    }

    /// Decode all frames in the file, calling handler for each decoded frame.
    /// Returns normally on EOF. More efficient than repeated `decodeNextFrame` calls
    /// as it unwraps optionals once and avoids per-frame throw/catch overhead.
    public func decodeAllFrames(handler: (DecodedFrame) throws -> Void) throws {
        guard let formatContext,
              let codecContext,
              let packet,
              let frame else {
            throw DecoderError.decodeFailed
        }

        var draining = false
        while true {
            if !draining {
                let readResult = av_read_frame(formatContext, packet)
                if readResult < 0 {
                    // Demuxer exhausted — drain frames still buffered in the codec
                    draining = true
                    avcodec_send_packet(codecContext, nil)
                } else {
                    guard packet.pointee.stream_index == audioStreamIndex else {
                        av_packet_unref(packet)
                        continue
                    }

                    avcodec_send_packet(codecContext, packet)
                    av_packet_unref(packet)
                }
            }

            while true {
                let receiveResult = avcodec_receive_frame(codecContext, frame)
                if receiveResult == AVERROR_EOF_VALUE { return }
                if receiveResult == -EAGAIN { break }
                if receiveResult < 0 {
                    throw DecoderError.decodeFailed
                }

                if let decoded = convertFrame(frame) {
                    do {
                        try handler(decoded)
                    } catch {
                        av_frame_unref(frame)
                        throw error
                    }
                }
                av_frame_unref(frame)
            }

            // EAGAIN while draining shouldn't occur; stop to avoid spinning
            if draining { return }
        }
    }

    // MARK: - Frame Conversion

    /// Unified frame conversion dispatcher — routes to the optimal path based on source format.
    private func convertFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> DecodedFrame? {
        switch conversionMode {
        case .passthrough:
            return passthroughDecodedFrame(frame)
        case .fastS32PToFloat, .fastS16PToFloat, .fastS32ToFloat, .fastS16ToFloat:
            #if canImport(Accelerate)
            return fastConvertIntFrame(frame)
            #else
            return nil
            #endif
        case .resample:
            return resampleDecodedFrame(frame)
        }
    }

    private func passthroughDecodedFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> DecodedFrame? {
        let sampleCount = frame.pointee.nb_samples
        guard sampleCount > 0,
              let extendedData = frame.pointee.extended_data else { return nil }

        let channelCount = Int(outputChannels)

        // Resize cached array only when channel count changes (typically once)
        if cachedChannelPointers.count != channelCount {
            guard let firstPtr = extendedData[0] else { return nil }
            let dummy = UnsafeRawPointer(firstPtr).assumingMemoryBound(to: Float.self)
            cachedChannelPointers = Array(repeating: dummy, count: channelCount)
        }

        // Update pointers in-place — no heap allocation (COW, refcount is 1)
        for ch in 0..<channelCount {
            guard let ptr = extendedData[ch] else { return nil }
            cachedChannelPointers[ch] = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
        }

        return DecodedFrame(
            channelData: cachedChannelPointers,
            frameCount: Int(sampleCount),
            sampleRate: Double(outputSampleRate),
            channelCount: channelCount
        )
    }

    #if canImport(Accelerate)
    /// SIMD-accelerated integer → float conversion, bypassing swr entirely.
    /// Handles both planar (stride 1, per-channel buffers) and interleaved
    /// (stride N, single buffer) layouts via vDSP stride parameters.
    private func fastConvertIntFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> DecodedFrame? {
        let sampleCount = Int(frame.pointee.nb_samples)
        guard sampleCount > 0,
              let extendedData = frame.pointee.extended_data else { return nil }

        let channelCount = Int(outputChannels)
        ensureResampleBuffers(channelCount: channelCount, minCapacity: sampleCount)

        let n = vDSP_Length(sampleCount)

        switch conversionMode {
        case .fastS32PToFloat:
            var scale = Float(1.0 / 2147483648.0)
            for ch in 0..<channelCount {
                guard let srcRaw = extendedData[ch] else { return nil }
                let src = UnsafeRawPointer(srcRaw).assumingMemoryBound(to: Int32.self)
                vDSP_vflt32(src, 1, resampleBuffers[ch], 1, n)
                vDSP_vsmul(resampleBuffers[ch], 1, &scale, resampleBuffers[ch], 1, n)
            }
        case .fastS32ToFloat:
            var scale = Float(1.0 / 2147483648.0)
            guard let srcRaw = extendedData[0] else { return nil }
            let src = UnsafeRawPointer(srcRaw).assumingMemoryBound(to: Int32.self)
            let inStride = vDSP_Stride(channelCount)
            for ch in 0..<channelCount {
                vDSP_vflt32(src.advanced(by: ch), inStride, resampleBuffers[ch], 1, n)
                vDSP_vsmul(resampleBuffers[ch], 1, &scale, resampleBuffers[ch], 1, n)
            }
        case .fastS16PToFloat:
            var scale = Float(1.0 / 32768.0)
            for ch in 0..<channelCount {
                guard let srcRaw = extendedData[ch] else { return nil }
                let src = UnsafeRawPointer(srcRaw).assumingMemoryBound(to: Int16.self)
                vDSP_vflt16(src, 1, resampleBuffers[ch], 1, n)
                vDSP_vsmul(resampleBuffers[ch], 1, &scale, resampleBuffers[ch], 1, n)
            }
        case .fastS16ToFloat:
            var scale = Float(1.0 / 32768.0)
            guard let srcRaw = extendedData[0] else { return nil }
            let src = UnsafeRawPointer(srcRaw).assumingMemoryBound(to: Int16.self)
            let inStride = vDSP_Stride(channelCount)
            for ch in 0..<channelCount {
                vDSP_vflt16(src.advanced(by: ch), inStride, resampleBuffers[ch], 1, n)
                vDSP_vsmul(resampleBuffers[ch], 1, &scale, resampleBuffers[ch], 1, n)
            }
        default:
            return nil
        }

        return buildDecodedFrame(frameCount: sampleCount)
    }
    #endif

    private func resampleDecodedFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> DecodedFrame? {
        guard let swrContext else { return nil }

        let outSamples = swr_get_out_samples(swrContext, frame.pointee.nb_samples)
        guard outSamples > 0 else { return nil }

        let channelCount = Int(outputChannels)
        let srcChannelCount = Int(channels)
        ensureResampleBuffers(channelCount: channelCount, minCapacity: Int(outSamples))

        guard let extendedData = frame.pointee.extended_data else { return nil }

        // Stack-allocate pointer arrays to avoid per-frame heap allocation
        let convertedSamples = withUnsafeTemporaryAllocation(
            of: UnsafeMutablePointer<UInt8>?.self, capacity: channelCount
        ) { outBuf in
            for i in 0..<channelCount {
                outBuf[i] = UnsafeMutableRawPointer(resampleBuffers[i])
                    .assumingMemoryBound(to: UInt8.self)
            }
            return withUnsafeTemporaryAllocation(
                of: UnsafePointer<UInt8>?.self, capacity: max(channelCount, srcChannelCount)
            ) { inBuf in
                var count = 0
                for i in 0..<srcChannelCount {
                    if let ptr = extendedData[i] {
                        inBuf[count] = UnsafePointer(ptr)
                        count += 1
                    }
                }
                while count < channelCount {
                    inBuf[count] = inBuf[0]
                    count += 1
                }
                return swr_convert(
                    swrContext,
                    outBuf.baseAddress!,
                    outSamples,
                    inBuf.baseAddress!,
                    frame.pointee.nb_samples
                )
            }
        }

        guard convertedSamples > 0 else { return nil }

        return buildDecodedFrame(frameCount: Int(convertedSamples))
    }

    /// Build a DecodedFrame from resampleBuffers, updating cachedChannelPointers in-place.
    private func buildDecodedFrame(frameCount: Int) -> DecodedFrame {
        let channelCount = Int(outputChannels)
        if cachedChannelPointers.count != channelCount {
            cachedChannelPointers = resampleBuffers.map { UnsafePointer($0) }
        } else {
            for i in 0..<channelCount {
                cachedChannelPointers[i] = UnsafePointer(resampleBuffers[i])
            }
        }
        return DecodedFrame(
            channelData: cachedChannelPointers,
            frameCount: frameCount,
            sampleRate: Double(outputSampleRate),
            channelCount: channelCount
        )
    }

    public func seek(to time: TimeInterval) {
        guard let formatContext, audioStreamIndex >= 0 else { return }

        let stream = formatContext.pointee.streams[Int(audioStreamIndex)]!
        let timeBase = stream.pointee.time_base
        let timestamp = Int64(time / av_q2d(timeBase))

        av_seek_frame(formatContext, audioStreamIndex, timestamp, AVSEEK_FLAG_BACKWARD)

        if let codecContext {
            avcodec_flush_buffers(codecContext)
        }

        // Seeking exits drain mode — avcodec_flush_buffers resets the codec so it
        // accepts packets again
        isDraining = false

        // Discard samples buffered in the resampler from before the seek.
        // (swr_convert with a nil output buffer flushes nothing — drop the
        // delayed samples explicitly.)
        if let swrContext {
            let delay = swr_get_delay(swrContext, Int64(outputSampleRate))
            if delay > 0 {
                swr_drop_output(swrContext, Int32(clamping: delay))
            }
        }
    }

    public func close() {
        // Free pre-allocated resample buffers
        for buf in resampleBuffers { buf.deallocate() }
        resampleBuffers = []
        resampleBufferCapacity = 0
        cachedChannelPointers = []

        if swrContext != nil {
            swr_free(&self.swrContext)
        }
        swrContext = nil

        if codecContext != nil {
            avcodec_free_context(&self.codecContext)
        }
        self.codecContext = nil

        if formatContext != nil {
            avformat_close_input(&self.formatContext)
        }
        self.formatContext = nil

        audioStreamIndex = -1
        duration = 0
        sampleRate = 0
        channels = 0
        bitrate = 0
        codecName = ""
        bitsPerSample = 0
        conversionMode = .resample
        isDraining = false
    }

    // MARK: - Format Conversion Helpers

    private func detectSourceSampleFormat() -> AudioSampleFormat {
        guard let ctx = codecContext else { return .float32 }
        return avSampleFormatToAudioSampleFormat(ctx.pointee.sample_fmt)
    }

    func avSampleFormatToAudioSampleFormat(_ fmt: AVSampleFormat) -> AudioSampleFormat {
        switch fmt {
        case AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P:
            .int16
        case AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P:
            .int32
        case AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP:
            .float32
        case AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBLP:
            .float64
        default:
            .float32
        }
    }

    func audioSampleFormatToAVSampleFormat(_ fmt: AudioSampleFormat) -> AVSampleFormat {
        switch fmt {
        case .int16:
            AV_SAMPLE_FMT_S16P
        case .int24, .int32:
            AV_SAMPLE_FMT_S32P
        case .float32:
            AV_SAMPLE_FMT_FLTP
        case .float64:
            AV_SAMPLE_FMT_DBLP
        }
    }
}
