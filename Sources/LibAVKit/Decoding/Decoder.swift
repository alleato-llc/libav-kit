import CFFmpeg
import Foundation

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

    /// Track if we're in passthrough mode (no resampling needed)
    private var isPassthrough: Bool = false

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

        // Check if we can use passthrough mode (no resampling)
        isPassthrough = checkPassthrough(ctx)

        if isPassthrough {
            // No resampler needed
            swrContext = nil
            return
        }

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

    private func checkPassthrough(_ ctx: UnsafeMutablePointer<AVCodecContext>) -> Bool {
        // Check if source format matches configured output format
        let sourceSampleRate = ctx.pointee.sample_rate
        let sourceChannels = ctx.pointee.ch_layout.nb_channels
        let sourceSampleFmt = ctx.pointee.sample_fmt

        // For passthrough, sample rate and channels must match
        guard sourceSampleRate == outputSampleRate,
              sourceChannels == outputChannels else {
            return false
        }

        // Sample format must be float32 planar (our standard output format for AVAudioEngine)
        // or match exactly
        if sourceSampleFmt == AV_SAMPLE_FMT_FLTP || sourceSampleFmt == outputSampleFormat {
            return true
        }

        return false
    }

    /// Decode the next frame and pass raw audio data to the handler via ``DecodedFrame``.
    /// The frame's pointers are only valid for the duration of the callback.
    /// Throws ``DecoderError/endOfFile`` when no more data is available.
    public func decodeNextFrame(handler: (DecodedFrame) throws -> Void) throws {
        guard let formatContext,
              let codecContext,
              let packet,
              let frame else {
            throw DecoderError.decodeFailed
        }

        while true {
            let readResult = av_read_frame(formatContext, packet)
            if readResult == AVERROR_EOF_VALUE || readResult == -EAGAIN {
                throw DecoderError.endOfFile
            }

            defer { av_packet_unref(packet) }

            guard packet.pointee.stream_index == audioStreamIndex else {
                continue
            }

            let sendResult = avcodec_send_packet(codecContext, packet)
            if sendResult < 0 { continue }

            while true {
                let receiveResult = avcodec_receive_frame(codecContext, frame)
                if receiveResult == -EAGAIN || receiveResult == AVERROR_EOF_VALUE {
                    break
                }
                if receiveResult < 0 {
                    throw DecoderError.decodeFailed
                }

                defer { av_frame_unref(frame) }

                if isPassthrough {
                    if let decoded = passthroughDecodedFrame(frame) {
                        try handler(decoded)
                        return
                    }
                } else {
                    try resampleDecodedFrame(frame, handler: handler)
                    return
                }
            }
        }
    }

    private func passthroughDecodedFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> DecodedFrame? {
        let sampleCount = frame.pointee.nb_samples
        guard sampleCount > 0,
              let extendedData = frame.pointee.extended_data else { return nil }

        var pointers: [UnsafePointer<Float>] = []
        for ch in 0..<Int(outputChannels) {
            guard let ptr = extendedData[ch] else { return nil }
            pointers.append(UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self))
        }

        return DecodedFrame(
            channelData: pointers,
            frameCount: Int(sampleCount),
            sampleRate: Double(outputSampleRate),
            channelCount: Int(outputChannels)
        )
    }

    private func resampleDecodedFrame(_ frame: UnsafeMutablePointer<AVFrame>, handler: (DecodedFrame) throws -> Void) throws {
        guard let swrContext else { return }

        let outSamples = swr_get_out_samples(swrContext, frame.pointee.nb_samples)
        guard outSamples > 0 else { return }

        // Allocate temporary planar buffers for resampled output
        let channelCount = Int(outputChannels)
        var buffers: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<channelCount {
            buffers.append(.allocate(capacity: Int(outSamples)))
        }
        defer {
            for buf in buffers { buf.deallocate() }
        }

        var outPointers: [UnsafeMutablePointer<UInt8>?] = buffers.map {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self)
        }

        guard let extendedData = frame.pointee.extended_data else { return }

        let convertedSamples = outPointers.withUnsafeMutableBufferPointer { outBufPtr -> Int32 in
            var inPointers: [UnsafePointer<UInt8>?] = []
            for i in 0..<Int(channels) {
                if let ptr = extendedData[i] {
                    inPointers.append(UnsafePointer(ptr))
                }
            }
            while inPointers.count < channelCount {
                if let first = inPointers.first {
                    inPointers.append(first)
                } else {
                    break
                }
            }

            return inPointers.withUnsafeBufferPointer { inBufPtr in
                swr_convert(
                    swrContext,
                    outBufPtr.baseAddress,
                    outSamples,
                    inBufPtr.baseAddress,
                    frame.pointee.nb_samples
                )
            }
        }

        guard convertedSamples > 0 else { return }

        let pointers: [UnsafePointer<Float>] = buffers.map { UnsafePointer($0) }
        let decoded = DecodedFrame(
            channelData: pointers,
            frameCount: Int(convertedSamples),
            sampleRate: Double(outputSampleRate),
            channelCount: channelCount
        )
        try handler(decoded)
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

        // Flush the resampler to clear any buffered samples from before the seek
        if let swrContext {
            // Passing nil input flushes the resampler
            swr_convert(swrContext, nil, 0, nil, 0)
        }
    }

    public func close() {
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
        isPassthrough = false
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
