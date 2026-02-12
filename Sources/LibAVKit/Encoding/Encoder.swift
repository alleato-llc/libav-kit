import CFFmpeg
import Foundation

/// FFmpeg-based audio encoder supporting all formats available through libavcodec
public final class Encoder: @unchecked Sendable {
    public init() {}
}

// MARK: - Encode Context

private extension Encoder {
    /// Groups the parameters needed by the encode loop into a single value
    struct EncodeContext {
        let decoder: Decoder
        let encCtx: UnsafeMutablePointer<AVCodecContext>
        let outFmtCtx: UnsafeMutablePointer<AVFormatContext>
        let outStream: UnsafeMutablePointer<AVStream>
        let swrCtx: OpaquePointer?
        let needsResample: Bool
        let outSampleRate: Int32
        let outChannels: Int32
        let sourceDuration: Double
        let progress: @Sendable (Double) -> Void
        let isCancelled: @Sendable () -> Bool
    }
}

// MARK: - Public API

extension Encoder {
    public static var supportedFormats: Set<OutputFormat> {
        Set(OutputFormat.allCases.filter { isEncoderAvailable(for: $0) })
    }

    /// Check whether the FFmpeg encoder for a given output format is available at runtime
    public static func isEncoderAvailable(for format: OutputFormat) -> Bool {
        let encoder = Encoder()
        let spec = encoder.encoderSpec(for: format)
        if let name = spec.encoderName {
            return avcodec_find_encoder_by_name(name) != nil
        }
        return avcodec_find_encoder(spec.codecId) != nil
    }

    public func encode(
        inputURL: URL,
        outputURL: URL,
        config: ConversionConfig,
        metadata: AudioMetadata? = nil,
        progress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        // 1. Open input and determine source parameters
        let decoder = Decoder()
        try decoder.open(url: inputURL)

        let sourceDuration = decoder.duration
        let outSampleRate = Int32(config.sampleRate ?? decoder.sampleRate)
        let decoderChannels = decoder.channels > 0 ? decoder.channels : 2
        let outChannels = Int32(config.channels ?? decoderChannels)
        let effectiveBitDepth = config.bitDepth ?? decoder.bitsPerSample

        // 2. Setup output format context and encoder
        let spec = encoderSpec(for: config.outputFormat, bitDepth: effectiveBitDepth)
        let (outFmtCtx, encCtxPtr, outStream) = try setupOutputContext(
            spec: spec,
            config: config,
            outputURL: outputURL,
            outSampleRate: outSampleRate,
            outChannels: outChannels,
            effectiveBitDepth: effectiveBitDepth
        )

        defer {
            var encCtx: UnsafeMutablePointer<AVCodecContext>? = encCtxPtr
            if outFmtCtx.pointee.pb != nil {
                avio_closep(&outFmtCtx.pointee.pb)
            }
            avformat_free_context(outFmtCtx)
            avcodec_free_context(&encCtx)
        }

        // 3. Configure decoder output and setup resampler
        let decoderOutputFormat = AudioOutputFormat(
            sampleRate: Double(outSampleRate),
            channelCount: Int(outChannels),
            sampleFormat: .float32,
            isInterleaved: false
        )
        try decoder.reconfigure(outputFormat: decoderOutputFormat)

        var swrCtx = try setupResampler(
            encCtx: encCtxPtr,
            outSampleRate: outSampleRate,
            outChannels: outChannels
        )
        let needsResample = swrCtx != nil
        defer { if swrCtx != nil { swr_free(&swrCtx) } }

        // 4. Write metadata tags and add cover art (before header)
        var coverArtStreamIndex: Int32?
        let metadataWriter = EncoderMetadataWriter()
        if let metadata {
            metadataWriter.write(metadata: metadata, to: outFmtCtx)
            if let coverArt = metadata.coverArt {
                if config.outputFormat.usesOggContainer {
                    metadataWriter.addCoverArtAsVorbisComment(coverArt, to: outFmtCtx)
                } else {
                    coverArtStreamIndex = metadataWriter.addCoverArtStream(
                        coverArt, to: outFmtCtx, outputFormat: config.outputFormat
                    )
                }
            }
        }

        // 5. Write header
        guard avformat_write_header(outFmtCtx, nil) >= 0 else {
            throw EncoderError.headerWriteFailed
        }

        // 5b. Write cover art packet (after header, before audio data)
        if let coverArt = metadata?.coverArt, let artStreamIdx = coverArtStreamIndex {
            metadataWriter.writeCoverArtPacket(coverArt, to: outFmtCtx, streamIndex: artStreamIdx)
        }

        // 6. Decode → resample → encode loop
        let context = EncodeContext(
            decoder: decoder,
            encCtx: encCtxPtr,
            outFmtCtx: outFmtCtx,
            outStream: outStream,
            swrCtx: swrCtx,
            needsResample: needsResample,
            outSampleRate: outSampleRate,
            outChannels: outChannels,
            sourceDuration: sourceDuration,
            progress: progress,
            isCancelled: isCancelled
        )
        try encodeLoop(context: context)

        // 7. Write trailer and finish
        av_write_trailer(outFmtCtx)
        decoder.close()
        progress(1.0)
    }
}

// MARK: - Encoding Pipeline Steps

private extension Encoder {
    func setupOutputContext(
        spec: EncoderSpec,
        config: ConversionConfig,
        outputURL: URL,
        outSampleRate: Int32,
        outChannels: Int32,
        effectiveBitDepth: Int
    ) throws -> (
        UnsafeMutablePointer<AVFormatContext>,
        UnsafeMutablePointer<AVCodecContext>,
        UnsafeMutablePointer<AVStream>
    ) {
        // Create output format context
        var outputFmtCtx: UnsafeMutablePointer<AVFormatContext>?
        let outputPath = outputURL.path

        let ret = avformat_alloc_output_context2(
            &outputFmtCtx, nil, spec.containerFormat, outputPath
        )
        guard ret >= 0, let outFmtCtx = outputFmtCtx else {
            throw EncoderError.outputFormatNotFound(config.outputFormat.fileExtension)
        }

        // Find encoder and create stream
        let (enc, outStream, encCtxPtr) = try findEncoderAndCreateStream(
            spec: spec,
            outFmtCtx: outFmtCtx,
            outSampleRate: outSampleRate,
            outChannels: outChannels,
            config: config,
            effectiveBitDepth: effectiveBitDepth
        )

        // Open encoder and configure output
        try openEncoderAndOutput(
            encCtxPtr: encCtxPtr,
            enc: enc,
            outFmtCtx: outFmtCtx,
            outStream: outStream,
            outputPath: outputPath
        )

        return (outFmtCtx, encCtxPtr, outStream)
    }

    func findEncoderAndCreateStream(
        spec: EncoderSpec,
        outFmtCtx: UnsafeMutablePointer<AVFormatContext>,
        outSampleRate: Int32,
        outChannels: Int32,
        config: ConversionConfig,
        effectiveBitDepth: Int
    ) throws -> (
        UnsafePointer<AVCodec>,
        UnsafeMutablePointer<AVStream>,
        UnsafeMutablePointer<AVCodecContext>
    ) {
        let encoder: UnsafePointer<AVCodec>? = if let encoderName = spec.encoderName {
            avcodec_find_encoder_by_name(encoderName)
        } else {
            avcodec_find_encoder(spec.codecId)
        }

        guard let enc = encoder else {
            avformat_free_context(outFmtCtx)
            throw EncoderError.encoderNotFound(
                spec.encoderName ?? String(cString: avcodec_get_name(spec.codecId))
            )
        }

        guard let outStream = avformat_new_stream(outFmtCtx, enc) else {
            avformat_free_context(outFmtCtx)
            throw EncoderError.encoderOpenFailed("Failed to create output stream")
        }

        guard let encCtxPtr = avcodec_alloc_context3(enc) else {
            avformat_free_context(outFmtCtx)
            throw EncoderError.encoderOpenFailed("Failed to allocate encoder context")
        }

        if let supportedFmts = enc.pointee.sample_fmts {
            encCtxPtr.pointee.sample_fmt = bestSampleFormat(
                from: supportedFmts, bitDepth: effectiveBitDepth
            )
        } else {
            // sample_fmts is deprecated in newer FFmpeg; infer format from codec ID
            encCtxPtr.pointee.sample_fmt = inferSampleFormat(for: spec.codecId)
        }

        encCtxPtr.pointee.sample_rate = outSampleRate
        av_channel_layout_default(&encCtxPtr.pointee.ch_layout, outChannels)

        // Validate sample rate against encoder's supported rates
        if let supportedRates = enc.pointee.supported_samplerates {
            var rates: [Int] = []
            var i = 0
            while supportedRates[i] != 0 {
                rates.append(Int(supportedRates[i]))
                i += 1
            }
            if !rates.isEmpty, !rates.contains(Int(outSampleRate)) {
                var ctx: UnsafeMutablePointer<AVCodecContext>? = encCtxPtr
                avcodec_free_context(&ctx)
                avformat_free_context(outFmtCtx)
                throw EncoderError.unsupportedSampleRate(
                    requested: Int(outSampleRate),
                    supported: rates.sorted(),
                    encoder: String(cString: enc.pointee.name)
                )
            }
        }

        configureBitrate(encCtx: encCtxPtr, config: config, format: config.outputFormat)

        if (outFmtCtx.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER) != 0 {
            encCtxPtr.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        return (enc, outStream, encCtxPtr)
    }

    func openEncoderAndOutput(
        encCtxPtr: UnsafeMutablePointer<AVCodecContext>,
        enc: UnsafePointer<AVCodec>,
        outFmtCtx: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>,
        outputPath: String
    ) throws {
        // Capture diagnostics before avcodec_open2 which may reset context on failure
        let encoderName = String(cString: enc.pointee.name)
        let sampleRate = encCtxPtr.pointee.sample_rate
        let sampleFmt = encCtxPtr.pointee.sample_fmt.rawValue
        let channels = encCtxPtr.pointee.ch_layout.nb_channels

        var ret = avcodec_open2(encCtxPtr, enc, nil)
        guard ret >= 0 else {
            var ctx: UnsafeMutablePointer<AVCodecContext>? = encCtxPtr
            avcodec_free_context(&ctx)
            avformat_free_context(outFmtCtx)
            throw EncoderError.encoderOpenFailed(
                "avcodec_open2 returned \(ret) (encoder \(encoderName), "
                    + "rate=\(sampleRate), fmt=\(sampleFmt), ch=\(channels))"
            )
        }

        ret = avcodec_parameters_from_context(outStream.pointee.codecpar, encCtxPtr)
        guard ret >= 0 else {
            var ctx: UnsafeMutablePointer<AVCodecContext>? = encCtxPtr
            avcodec_free_context(&ctx)
            avformat_free_context(outFmtCtx)
            throw EncoderError.encoderOpenFailed("Failed to copy codec parameters")
        }

        outStream.pointee.time_base = encCtxPtr.pointee.time_base

        if (outFmtCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            ret = avio_open(&outFmtCtx.pointee.pb, outputPath, AVIO_FLAG_WRITE)
            guard ret >= 0 else {
                var ctx: UnsafeMutablePointer<AVCodecContext>? = encCtxPtr
                avcodec_free_context(&ctx)
                avformat_free_context(outFmtCtx)
                throw EncoderError.outputOpenFailed(outputPath)
            }
        }
    }

    func setupResampler(
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        outSampleRate: Int32,
        outChannels: Int32
    ) throws -> OpaquePointer? {
        guard encCtx.pointee.sample_fmt != AV_SAMPLE_FMT_FLTP else {
            return nil
        }

        var swrCtx: OpaquePointer?
        var inLayout = AVChannelLayout()
        av_channel_layout_default(&inLayout, outChannels)

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, outChannels)

        let ret = swr_alloc_set_opts2(
            &swrCtx,
            &outLayout,
            encCtx.pointee.sample_fmt,
            outSampleRate,
            &inLayout,
            AV_SAMPLE_FMT_FLTP,
            outSampleRate,
            0,
            nil
        )

        guard ret >= 0, let swr = swrCtx else {
            throw EncoderError.resamplerFailed
        }

        guard swr_init(swr) >= 0 else {
            swr_free(&swrCtx)
            throw EncoderError.resamplerFailed
        }

        return swrCtx
    }

    func encodeLoop(context ctx: EncodeContext) throws {
        var encodeFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        var encodePacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()

        guard encodeFrame != nil, encodePacket != nil else {
            throw EncoderError.encodingFailed("Failed to allocate frame or packet")
        }

        defer {
            av_frame_free(&encodeFrame)
            av_packet_free(&encodePacket)
        }

        let frameSize = ctx.encCtx.pointee.frame_size

        // For codecs with a fixed frame_size, use AVAudioFifo to accumulate
        // decoded samples and drain them in exact frame_size chunks.
        var fifo: OpaquePointer?
        if frameSize > 0 {
            fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, ctx.outChannels, frameSize)
            guard fifo != nil else {
                throw EncoderError.encodingFailed("Failed to allocate audio FIFO")
            }
        }
        defer { if let fifo { av_audio_fifo_free(fifo) } }

        var totalSamplesEncoded: Int64 = 0
        let totalExpectedSamples = Int64(ctx.sourceDuration * Double(ctx.outSampleRate))

        var decodeFinished = false
        while !decodeFinished {
            if ctx.isCancelled() { throw EncoderError.cancelled }

            do {
                try ctx.decoder.decodeNextFrame { frame in
                    guard frame.frameCount > 0 else { return }

                    guard let framePtr = encodeFrame, let packetPtr = encodePacket else {
                        throw EncoderError.encodingFailed("Frame or packet deallocated unexpectedly")
                    }

                    if let fifo {
                        // Write decoded samples into the FIFO
                        writeDecodedFrameToFifo(fifo, frame: frame, channels: ctx.outChannels)

                        // Drain full frames
                        while av_audio_fifo_size(fifo) >= frameSize {
                            totalSamplesEncoded += try encodeFromFifo(
                                ctx: ctx, fifo: fifo, chunkSize: frameSize,
                                framePtr: framePtr, packetPtr: packetPtr,
                                ptsOffset: totalSamplesEncoded
                            )
                        }
                    } else {
                        // Variable frame_size: send buffer directly
                        totalSamplesEncoded += try encodeFromDecodedFrame(
                            ctx: ctx, frame: frame, frameCount: Int32(frame.frameCount),
                            framePtr: framePtr, packetPtr: packetPtr,
                            ptsOffset: totalSamplesEncoded
                        )
                    }

                    if totalExpectedSamples > 0 {
                        ctx.progress(min(1.0, Double(totalSamplesEncoded) / Double(totalExpectedSamples)))
                    }
                }
            } catch DecoderError.endOfFile {
                decodeFinished = true
            }
        }

        // Flush remaining samples from the FIFO (final short frame)
        if let fifo, let framePtr = encodeFrame, let packetPtr = encodePacket {
            let remaining = av_audio_fifo_size(fifo)
            if remaining > 0 {
                totalSamplesEncoded += try encodeFromFifo(
                    ctx: ctx, fifo: fifo, chunkSize: remaining,
                    framePtr: framePtr, packetPtr: packetPtr,
                    ptsOffset: totalSamplesEncoded
                )
            }
        }

        // Flush encoder
        if let packetPtr = encodePacket {
            try sendFrameAndWritePackets(
                encCtx: ctx.encCtx,
                frame: nil,
                packet: packetPtr,
                outFmtCtx: ctx.outFmtCtx,
                outStream: ctx.outStream
            )
        }
    }

    /// Write decoded planar float samples from a PCM buffer into the FIFO.
    func writeDecodedFrameToFifo(
        _ fifo: OpaquePointer,
        frame: DecodedFrame,
        channels: Int32
    ) {
        let sampleCount = Int32(frame.frameCount)

        // Build array of channel pointers (FLTP layout matches planar float data)
        var ptrs: [UnsafeMutableRawPointer?] = (0 ..< Int(channels)).map { ch in
            UnsafeMutableRawPointer(mutating: frame.channelData[ch])
        }
        ptrs.withUnsafeMutableBufferPointer { buf in
            _ = av_audio_fifo_write(fifo, buf.baseAddress, sampleCount)
        }
    }

    /// Read chunkSize samples from the FIFO, resample if needed, and encode.
    func encodeFromFifo(
        ctx: EncodeContext,
        fifo: OpaquePointer,
        chunkSize: Int32,
        framePtr: UnsafeMutablePointer<AVFrame>,
        packetPtr: UnsafeMutablePointer<AVPacket>,
        ptsOffset: Int64
    ) throws -> Int64 {
        // Allocate a temporary FLTP frame to read FIFO data into
        var readFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let tempFrame = readFrame else {
            throw EncoderError.encodingFailed("Failed to allocate FIFO read frame")
        }
        defer { av_frame_free(&readFrame) }

        tempFrame.pointee.nb_samples = chunkSize
        tempFrame.pointee.format = Int32(AV_SAMPLE_FMT_FLTP.rawValue)
        tempFrame.pointee.sample_rate = ctx.outSampleRate
        av_channel_layout_default(&tempFrame.pointee.ch_layout, ctx.outChannels)
        guard av_frame_get_buffer(tempFrame, 0) >= 0 else {
            throw EncoderError.encodingFailed("Failed to allocate FIFO read frame buffer")
        }

        // Read from FIFO into the temporary frame
        var readPtrs: [UnsafeMutableRawPointer?] = (0 ..< Int(ctx.outChannels)).map { ch in
            UnsafeMutableRawPointer(tempFrame.pointee.extended_data[ch]!)
        }
        let readCount = readPtrs.withUnsafeMutableBufferPointer { buf in
            av_audio_fifo_read(fifo, buf.baseAddress, chunkSize)
        }
        guard readCount > 0 else {
            throw EncoderError.encodingFailed("Failed to read from audio FIFO")
        }
        tempFrame.pointee.nb_samples = readCount

        // Prepare the encode frame
        try prepareEncodeFrame(
            framePtr: framePtr,
            encCtx: ctx.encCtx,
            frameCount: readCount,
            outSampleRate: ctx.outSampleRate
        )
        framePtr.pointee.pts = ptsOffset

        if ctx.needsResample, let swr = ctx.swrCtx {
            // Resample from FLTP temp frame into the encode frame
            let inPointers: [UnsafePointer<UInt8>?] = (0 ..< Int(ctx.outChannels)).map { ch in
                UnsafePointer(tempFrame.pointee.extended_data[ch]!)
            }
            inPointers.withUnsafeBufferPointer { inBuf in
                var outPtrs: [UnsafeMutablePointer<UInt8>?] = (0 ..< Int(ctx.outChannels)).map { ch in
                    framePtr.pointee.extended_data[ch]
                }
                outPtrs.withUnsafeMutableBufferPointer { outBuf in
                    let converted = swr_convert(
                        swr, outBuf.baseAddress, readCount, inBuf.baseAddress, readCount
                    )
                    if converted > 0 {
                        framePtr.pointee.nb_samples = converted
                    }
                }
            }
        } else {
            // Direct copy: FLTP temp frame → encode frame
            for ch in 0 ..< Int(ctx.outChannels) {
                if let dst = framePtr.pointee.extended_data[ch],
                   let src = tempFrame.pointee.extended_data[ch] {
                    dst.update(from: src, count: Int(readCount) * MemoryLayout<Float>.size)
                }
            }
        }

        let samplesEncoded = Int64(framePtr.pointee.nb_samples)

        try sendFrameAndWritePackets(
            encCtx: ctx.encCtx,
            frame: framePtr,
            packet: packetPtr,
            outFmtCtx: ctx.outFmtCtx,
            outStream: ctx.outStream
        )

        av_frame_unref(framePtr)
        return samplesEncoded
    }

    /// Encode directly from a PCM buffer (for variable frame_size codecs like PCM, FLAC).
    func encodeFromDecodedFrame(
        ctx: EncodeContext,
        frame: DecodedFrame,
        frameCount: Int32,
        framePtr: UnsafeMutablePointer<AVFrame>,
        packetPtr: UnsafeMutablePointer<AVPacket>,
        ptsOffset: Int64
    ) throws -> Int64 {
        try prepareEncodeFrame(
            framePtr: framePtr,
            encCtx: ctx.encCtx,
            frameCount: frameCount,
            outSampleRate: ctx.outSampleRate
        )
        framePtr.pointee.pts = ptsOffset

        if ctx.needsResample, let swr = ctx.swrCtx {
            resampleDecodedFrameIntoEncodeFrame(
                swr: swr,
                framePtr: framePtr,
                decodedFrame: frame,
                frameCount: frameCount,
                outChannels: ctx.outChannels
            )
        } else {
            copyDecodedFrameData(
                framePtr: framePtr,
                decodedFrame: frame,
                frameCount: frameCount,
                outChannels: ctx.outChannels
            )
        }

        let samplesEncoded = Int64(framePtr.pointee.nb_samples)

        try sendFrameAndWritePackets(
            encCtx: ctx.encCtx,
            frame: framePtr,
            packet: packetPtr,
            outFmtCtx: ctx.outFmtCtx,
            outStream: ctx.outStream
        )

        av_frame_unref(framePtr)
        return samplesEncoded
    }

    func prepareEncodeFrame(
        framePtr: UnsafeMutablePointer<AVFrame>,
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        frameCount: Int32,
        outSampleRate: Int32
    ) throws {
        framePtr.pointee.nb_samples = frameCount
        framePtr.pointee.format = Int32(encCtx.pointee.sample_fmt.rawValue)
        framePtr.pointee.sample_rate = outSampleRate
        av_channel_layout_copy(&framePtr.pointee.ch_layout, &encCtx.pointee.ch_layout)

        guard av_frame_get_buffer(framePtr, 0) >= 0 else {
            throw EncoderError.encodingFailed("Failed to allocate encode frame buffer")
        }
        guard av_frame_make_writable(framePtr) >= 0 else {
            throw EncoderError.encodingFailed("Failed to make frame writable")
        }
    }

    func resampleDecodedFrameIntoEncodeFrame(
        swr: OpaquePointer,
        framePtr: UnsafeMutablePointer<AVFrame>,
        decodedFrame: DecodedFrame,
        frameCount: Int32,
        outChannels: Int32
    ) {
        let inPointers: [UnsafePointer<UInt8>?] = (0 ..< Int(outChannels)).map { ch in
            UnsafeRawPointer(decodedFrame.channelData[ch]).assumingMemoryBound(to: UInt8.self)
        }

        inPointers.withUnsafeBufferPointer { inBuf in
            var outPtrs: [UnsafeMutablePointer<UInt8>?] = (0 ..< Int(outChannels)).map { ch in
                framePtr.pointee.extended_data[ch]
            }
            outPtrs.withUnsafeMutableBufferPointer { outBuf in
                let converted = swr_convert(
                    swr, outBuf.baseAddress, frameCount, inBuf.baseAddress, frameCount
                )
                if converted > 0 {
                    framePtr.pointee.nb_samples = converted
                }
            }
        }
    }

    func copyDecodedFrameData(
        framePtr: UnsafeMutablePointer<AVFrame>,
        decodedFrame: DecodedFrame,
        frameCount: Int32,
        outChannels: Int32
    ) {
        for ch in 0 ..< Int(outChannels) {
            if let dst = framePtr.pointee.extended_data[ch] {
                let src = UnsafeRawPointer(decodedFrame.channelData[ch])
                dst.update(
                    from: src.assumingMemoryBound(to: UInt8.self),
                    count: Int(frameCount) * MemoryLayout<Float>.size
                )
            }
        }
    }

    func sendFrameAndWritePackets(
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        frame: UnsafeMutablePointer<AVFrame>?,
        packet: UnsafeMutablePointer<AVPacket>,
        outFmtCtx: UnsafeMutablePointer<AVFormatContext>,
        outStream: UnsafeMutablePointer<AVStream>
    ) throws {
        var ret = avcodec_send_frame(encCtx, frame)
        if ret < 0, ret != -EAGAIN {
            throw EncoderError.encodingFailed("avcodec_send_frame returned \(ret)")
        }

        while true {
            ret = avcodec_receive_packet(encCtx, packet)
            if ret == -EAGAIN || ret == averrorEOFValue {
                break
            }
            if ret < 0 {
                throw EncoderError.encodingFailed("avcodec_receive_packet returned \(ret)")
            }

            av_packet_rescale_ts(packet, encCtx.pointee.time_base, outStream.pointee.time_base)
            packet.pointee.stream_index = outStream.pointee.index

            ret = av_interleaved_write_frame(outFmtCtx, packet)
            av_packet_unref(packet)

            if ret < 0 {
                throw EncoderError.encodingFailed("av_interleaved_write_frame returned \(ret)")
            }
        }
    }

    /// Select the encoder sample format that best matches the requested bit depth.
    func bestSampleFormat(
        from supportedFmts: UnsafePointer<AVSampleFormat>,
        bitDepth: Int
    ) -> AVSampleFormat {
        // Collect all supported formats
        var formats: [AVSampleFormat] = []
        var i = 0
        while supportedFmts[i] != AV_SAMPLE_FMT_NONE {
            formats.append(supportedFmts[i])
            i += 1
        }
        guard !formats.isEmpty else { return AV_SAMPLE_FMT_FLTP }

        // Map bit depth to preferred sample formats (planar and interleaved variants)
        let preferred: [AVSampleFormat] = switch bitDepth {
        case ...16:
            [AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_S16]
        case 17 ... 24:
            [AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_S32]
        default:
            [AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_FLT]
        }

        for fmt in preferred {
            if formats.contains(fmt) { return fmt }
        }
        return formats[0]
    }

    func inferSampleFormat(for codecId: AVCodecID) -> AVSampleFormat {
        switch codecId {
        case AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S16BE:
            AV_SAMPLE_FMT_S16
        case AV_CODEC_ID_PCM_S32LE, AV_CODEC_ID_PCM_S32BE,
             AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_S24BE:
            AV_SAMPLE_FMT_S32
        case AV_CODEC_ID_PCM_F32LE, AV_CODEC_ID_PCM_F32BE:
            AV_SAMPLE_FMT_FLT
        case AV_CODEC_ID_PCM_F64LE, AV_CODEC_ID_PCM_F64BE:
            AV_SAMPLE_FMT_DBL
        default:
            AV_SAMPLE_FMT_FLTP
        }
    }
}

private let averrorEOFValue: Int32 = -541_478_725
