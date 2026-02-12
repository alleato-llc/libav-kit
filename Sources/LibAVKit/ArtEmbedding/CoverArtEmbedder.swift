import CFFmpeg
import Foundation

/// Embeds or removes cover art in audio files using the C library (no CLI shelling).
/// Uses the same remux pattern as `TagWriter`: open input, create output,
/// stream-copy all packets, then atomically replace the original.
public final class CoverArtEmbedder: @unchecked Sendable {
    public init() {}

    /// Embed cover art image data into an audio file.
    /// - Parameters:
    ///   - url: The audio file to embed art into
    ///   - imageData: Raw image data (JPEG or PNG)
    ///   - isOggContainer: Whether this is an OGG-based format (Opus, Vorbis).
    ///     OGG containers use METADATA_BLOCK_PICTURE Vorbis comment instead of
    ///     an attached picture stream.
    public func embed(in url: URL, imageData: Data, isOggContainer: Bool) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoverArtEmbedderError.fileNotFound(url)
        }

        let tempOutputURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: tempOutputURL) }

        try remuxWithArt(
            inputURL: url,
            outputURL: tempOutputURL,
            imageData: imageData,
            isOggContainer: isOggContainer
        )

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempOutputURL)
        } catch {
            throw CoverArtEmbedderError.replaceFailed(error.localizedDescription)
        }
    }

    /// Remove embedded cover art from an audio file.
    /// - Parameter url: The audio file to remove art from
    public func remove(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CoverArtEmbedderError.fileNotFound(url)
        }

        let tempOutputURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: tempOutputURL) }

        try remuxWithoutArt(inputURL: url, outputURL: tempOutputURL)

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempOutputURL)
        } catch {
            throw CoverArtEmbedderError.replaceFailed(error.localizedDescription)
        }
    }

    // MARK: - Private: Embed

    private func remuxWithArt(
        inputURL: URL,
        outputURL: URL,
        imageData: Data,
        isOggContainer: Bool
    ) throws {
        // Open input
        var inCtxPtr: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&inCtxPtr, inputURL.path, nil, nil) == 0,
              let inCtx = inCtxPtr else {
            throw CoverArtEmbedderError.openInputFailed(inputURL.path)
        }
        defer { avformat_close_input(&inCtxPtr) }

        guard avformat_find_stream_info(inCtx, nil) >= 0 else {
            throw CoverArtEmbedderError.streamInfoFailed
        }

        // Create output
        var outCtxPtr: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outCtxPtr, nil, nil, outputURL.path) >= 0,
              let outCtx = outCtxPtr else {
            throw CoverArtEmbedderError.outputFormatFailed
        }
        defer {
            if outCtx.pointee.pb != nil {
                avio_closep(&outCtx.pointee.pb)
            }
            avformat_free_context(outCtx)
        }

        // Copy streams, skipping existing art streams (we'll add new art)
        var streamMapping = [Int]()
        var outputStreamIndex = 0
        for i in 0 ..< Int(inCtx.pointee.nb_streams) {
            let inStream = inCtx.pointee.streams[i]!
            let codecType = inStream.pointee.codecpar.pointee.codec_type

            // Skip existing attached picture streams (we're replacing art)
            if codecType == AVMEDIA_TYPE_VIDEO,
               (inStream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 {
                streamMapping.append(-1)
                continue
            }

            guard codecType == AVMEDIA_TYPE_AUDIO
                || codecType == AVMEDIA_TYPE_VIDEO
                || codecType == AVMEDIA_TYPE_DATA
                || codecType == AVMEDIA_TYPE_SUBTITLE else {
                streamMapping.append(-1)
                continue
            }

            streamMapping.append(outputStreamIndex)
            outputStreamIndex += 1

            guard let outStream = avformat_new_stream(outCtx, nil) else {
                throw CoverArtEmbedderError.streamCopyFailed
            }
            guard avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar) >= 0 else {
                throw CoverArtEmbedderError.streamCopyFailed
            }
            outStream.pointee.time_base = inStream.pointee.time_base
            outStream.pointee.disposition = inStream.pointee.disposition
            outStream.pointee.codecpar.pointee.codec_tag = 0
        }

        // Copy existing metadata
        av_dict_copy(&outCtx.pointee.metadata, inCtx.pointee.metadata, 0)

        // Add cover art
        var artStreamIndex: Int32?
        if isOggContainer {
            // OGG: add as METADATA_BLOCK_PICTURE Vorbis comment
            if let base64 = VorbisPictureBlock.base64Encoded(imageData: imageData) {
                av_dict_set(&outCtx.pointee.metadata, "METADATA_BLOCK_PICTURE", base64, 0)
            }
        } else {
            // Non-OGG: add video stream with attached picture disposition
            if let stream = avformat_new_stream(outCtx, nil) {
                let dims = VorbisPictureBlock.extractImageDimensions(imageData)
                let codecId = detectImageCodec(imageData)
                stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_VIDEO
                stream.pointee.codecpar.pointee.codec_id = codecId
                stream.pointee.codecpar.pointee.width = dims.width
                stream.pointee.codecpar.pointee.height = dims.height
                stream.pointee.disposition = AV_DISPOSITION_ATTACHED_PIC
                artStreamIndex = stream.pointee.index
            }
        }

        // Open output file
        guard avio_open(&outCtx.pointee.pb, outputURL.path, AVIO_FLAG_WRITE) >= 0 else {
            throw CoverArtEmbedderError.outputOpenFailed(outputURL.path)
        }

        // Write header
        guard avformat_write_header(outCtx, nil) >= 0 else {
            throw CoverArtEmbedderError.headerWriteFailed
        }

        // Write art packet for non-OGG (after header)
        if let artIdx = artStreamIndex {
            writeArtPacket(imageData: imageData, to: outCtx, streamIndex: artIdx)
        }

        // Stream-copy all packets
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        while av_read_frame(inCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }

            let streamIndex = Int(packet!.pointee.stream_index)
            guard streamIndex < streamMapping.count else { continue }

            let mappedIndex = streamMapping[streamIndex]
            guard mappedIndex >= 0 else { continue }

            let inStream = inCtx.pointee.streams[streamIndex]!
            let outStream = outCtx.pointee.streams[mappedIndex]!

            packet!.pointee.stream_index = Int32(mappedIndex)
            av_packet_rescale_ts(packet, inStream.pointee.time_base, outStream.pointee.time_base)
            packet!.pointee.pos = -1

            av_interleaved_write_frame(outCtx, packet)
        }

        av_write_trailer(outCtx)
    }

    // MARK: - Private: Remove

    private func remuxWithoutArt(inputURL: URL, outputURL: URL) throws {
        var inCtxPtr: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&inCtxPtr, inputURL.path, nil, nil) == 0,
              let inCtx = inCtxPtr else {
            throw CoverArtEmbedderError.openInputFailed(inputURL.path)
        }
        defer { avformat_close_input(&inCtxPtr) }

        guard avformat_find_stream_info(inCtx, nil) >= 0 else {
            throw CoverArtEmbedderError.streamInfoFailed
        }

        var outCtxPtr: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outCtxPtr, nil, nil, outputURL.path) >= 0,
              let outCtx = outCtxPtr else {
            throw CoverArtEmbedderError.outputFormatFailed
        }
        defer {
            if outCtx.pointee.pb != nil {
                avio_closep(&outCtx.pointee.pb)
            }
            avformat_free_context(outCtx)
        }

        // Copy streams, skipping attached picture streams
        var streamMapping = [Int]()
        var outputStreamIndex = 0
        for i in 0 ..< Int(inCtx.pointee.nb_streams) {
            let inStream = inCtx.pointee.streams[i]!
            let codecType = inStream.pointee.codecpar.pointee.codec_type

            // Skip attached picture streams
            if codecType == AVMEDIA_TYPE_VIDEO,
               (inStream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 {
                streamMapping.append(-1)
                continue
            }

            guard codecType == AVMEDIA_TYPE_AUDIO
                || codecType == AVMEDIA_TYPE_VIDEO
                || codecType == AVMEDIA_TYPE_DATA
                || codecType == AVMEDIA_TYPE_SUBTITLE else {
                streamMapping.append(-1)
                continue
            }

            streamMapping.append(outputStreamIndex)
            outputStreamIndex += 1

            guard let outStream = avformat_new_stream(outCtx, nil) else {
                throw CoverArtEmbedderError.streamCopyFailed
            }
            guard avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar) >= 0 else {
                throw CoverArtEmbedderError.streamCopyFailed
            }
            outStream.pointee.time_base = inStream.pointee.time_base
            outStream.pointee.disposition = inStream.pointee.disposition
            outStream.pointee.codecpar.pointee.codec_tag = 0
        }

        // Copy metadata, removing METADATA_BLOCK_PICTURE (for OGG art removal)
        av_dict_copy(&outCtx.pointee.metadata, inCtx.pointee.metadata, 0)
        av_dict_set(&outCtx.pointee.metadata, "METADATA_BLOCK_PICTURE", nil, 0)

        guard avio_open(&outCtx.pointee.pb, outputURL.path, AVIO_FLAG_WRITE) >= 0 else {
            throw CoverArtEmbedderError.outputOpenFailed(outputURL.path)
        }

        guard avformat_write_header(outCtx, nil) >= 0 else {
            throw CoverArtEmbedderError.headerWriteFailed
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        while av_read_frame(inCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }

            let streamIndex = Int(packet!.pointee.stream_index)
            guard streamIndex < streamMapping.count else { continue }

            let mappedIndex = streamMapping[streamIndex]
            guard mappedIndex >= 0 else { continue }

            let inStream = inCtx.pointee.streams[streamIndex]!
            let outStream = outCtx.pointee.streams[mappedIndex]!

            packet!.pointee.stream_index = Int32(mappedIndex)
            av_packet_rescale_ts(packet, inStream.pointee.time_base, outStream.pointee.time_base)
            packet!.pointee.pos = -1

            av_interleaved_write_frame(outCtx, packet)
        }

        av_write_trailer(outCtx)
    }

    // MARK: - Helpers

    private func writeArtPacket(
        imageData: Data,
        to formatContext: UnsafeMutablePointer<AVFormatContext>,
        streamIndex: Int32
    ) {
        var pktPtr: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard let pkt = pktPtr else { return }
        defer { av_packet_free(&pktPtr) }

        let size = Int32(imageData.count)
        guard av_new_packet(pkt, size) >= 0 else { return }

        imageData.withUnsafeBytes { bytes in
            guard let src = bytes.baseAddress else { return }
            pkt.pointee.data.update(
                from: src.assumingMemoryBound(to: UInt8.self),
                count: Int(size)
            )
        }
        pkt.pointee.stream_index = streamIndex
        pkt.pointee.flags |= AV_PKT_FLAG_KEY

        av_interleaved_write_frame(formatContext, pkt)
    }

    private func detectImageCodec(_ data: Data) -> AVCodecID {
        guard data.count >= 4 else { return AV_CODEC_ID_MJPEG }

        if data[data.startIndex] == 0x89,
           data[data.startIndex + 1] == 0x50,
           data[data.startIndex + 2] == 0x4E,
           data[data.startIndex + 3] == 0x47 {
            return AV_CODEC_ID_PNG
        }

        return AV_CODEC_ID_MJPEG
    }
}

public enum CoverArtEmbedderError: Error, LocalizedError {
    case fileNotFound(URL)
    case openInputFailed(String)
    case streamInfoFailed
    case outputFormatFailed
    case streamCopyFailed
    case outputOpenFailed(String)
    case headerWriteFailed
    case replaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(url):
            "Audio file not found: \(url.lastPathComponent)"
        case let .openInputFailed(path):
            "Failed to open input file: \(path)"
        case .streamInfoFailed:
            "Failed to read stream info"
        case .outputFormatFailed:
            "Failed to create output format context"
        case .streamCopyFailed:
            "Failed to copy stream parameters"
        case let .outputOpenFailed(path):
            "Failed to open output file: \(path)"
        case .headerWriteFailed:
            "Failed to write output header"
        case let .replaceFailed(detail):
            "Failed to replace original file: \(detail)"
        }
    }
}
