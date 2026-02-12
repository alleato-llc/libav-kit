import CFFmpeg
import Foundation

/// Writes metadata tags to existing audio files via remuxing (no re-encoding).
public final class TagWriter: @unchecked Sendable {
    public init() {}

    /// Write metadata changes to a file, atomically replacing the original.
    /// Uses stream-copy (remux) to avoid any re-encoding.
    public func write(to url: URL, changes: MetadataChanges) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TagWriterError.fileNotFound(url)
        }

        // Create temp output URL in the same directory for atomic replace
        let tempOutputURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")

        defer { try? FileManager.default.removeItem(at: tempOutputURL) }

        try remux(inputURL: url, outputURL: tempOutputURL, changes: changes)

        // Atomic replace original with temp
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempOutputURL)
        } catch {
            throw TagWriterError.atomicReplaceFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func remux(inputURL: URL, outputURL: URL, changes: MetadataChanges) throws {
        // Open input
        var inCtxPtr: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&inCtxPtr, inputURL.path, nil, nil) == 0,
              let inCtx = inCtxPtr else {
            throw TagWriterError.openInputFailed(inputURL.path)
        }
        defer { avformat_close_input(&inCtxPtr) }

        guard avformat_find_stream_info(inCtx, nil) >= 0 else {
            throw TagWriterError.streamInfoFailed
        }

        // Create output format context
        var outCtxPtr: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&outCtxPtr, nil, nil, outputURL.path) >= 0,
              let outCtx = outCtxPtr else {
            throw TagWriterError.outputFormatFailed
        }
        defer {
            if outCtx.pointee.pb != nil {
                avio_closep(&outCtx.pointee.pb)
            }
            avformat_free_context(outCtx)
        }

        // Copy all streams from input to output
        var streamMapping = [Int]()
        var outputStreamIndex = 0
        for i in 0 ..< Int(inCtx.pointee.nb_streams) {
            let inStream = inCtx.pointee.streams[i]!
            let codecType = inStream.pointee.codecpar.pointee.codec_type

            // Copy audio, video (cover art), and data streams
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
                throw TagWriterError.streamCopyFailed
            }

            guard avcodec_parameters_copy(outStream.pointee.codecpar, inStream.pointee.codecpar) >= 0 else {
                throw TagWriterError.streamCopyFailed
            }

            outStream.pointee.time_base = inStream.pointee.time_base

            // Copy stream disposition (important for attached pictures)
            outStream.pointee.disposition = inStream.pointee.disposition
            outStream.pointee.codecpar.pointee.codec_tag = 0
        }

        // Copy existing metadata, then apply changes
        av_dict_copy(&outCtx.pointee.metadata, inCtx.pointee.metadata, 0)
        applyChanges(changes, to: &outCtx.pointee.metadata)

        // Open output file
        guard avio_open(&outCtx.pointee.pb, outputURL.path, AVIO_FLAG_WRITE) >= 0 else {
            throw TagWriterError.outputOpenFailed(outputURL.path)
        }

        // Write header
        guard avformat_write_header(outCtx, nil) >= 0 else {
            throw TagWriterError.headerWriteFailed
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

            // Rescale timestamps
            packet!.pointee.stream_index = Int32(mappedIndex)
            av_packet_rescale_ts(packet, inStream.pointee.time_base, outStream.pointee.time_base)
            packet!.pointee.pos = -1

            let ret = av_interleaved_write_frame(outCtx, packet)
            if ret < 0 {
                throw TagWriterError.writeFailed("av_interleaved_write_frame returned \(ret)")
            }
        }

        // Write trailer
        av_write_trailer(outCtx)
    }

    private func applyChanges(_ changes: MetadataChanges, to dict: inout OpaquePointer?) {
        if let title = changes.title {
            av_dict_set(&dict, "title", title, 0)
        }
        if let artist = changes.artistName {
            av_dict_set(&dict, "artist", artist, 0)
        }
        if let album = changes.albumTitle {
            av_dict_set(&dict, "album", album, 0)
        }
        if let track = changes.trackNumber {
            av_dict_set(&dict, "track", String(track), 0)
        }
        if let disc = changes.discNumber {
            av_dict_set(&dict, "disc", String(disc), 0)
        }
        if let genre = changes.genre {
            av_dict_set(&dict, "genre", genre, 0)
        }
        if let year = changes.year {
            av_dict_set(&dict, "date", String(year), 0)
        }

        // Extended tags (COMPOSER, CONDUCTOR, etc.)
        var commentValue = changes.extendedTags["COMMENT"]
        for (key, value) in changes.extendedTags where key != "COMMENT" {
            av_dict_set(&dict, key, value, 0)
        }

        // Custom tags
        if changes.embedCustomTagsInComment, !changes.customTags.isEmpty {
            let customTagPairs = changes.customTags.map { ($0.key, $0.value) }
            let formatted = CustomTagParser.formatMultiple(customTagPairs)
            if let existing = commentValue, !existing.isEmpty {
                commentValue = existing + "\n" + formatted
            } else {
                commentValue = formatted
            }
        } else {
            for (key, value) in changes.customTags {
                av_dict_set(&dict, key, value, 0)
            }
        }

        if let comment = commentValue {
            av_dict_set(&dict, "COMMENT", comment, 0)
        }
    }
}

public enum TagWriterError: Error, LocalizedError {
    case fileNotFound(URL)
    case openInputFailed(String)
    case streamInfoFailed
    case outputFormatFailed
    case streamCopyFailed
    case outputOpenFailed(String)
    case headerWriteFailed
    case writeFailed(String)
    case atomicReplaceFailed(String)

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
        case let .writeFailed(detail):
            "Failed to write packet: \(detail)"
        case let .atomicReplaceFailed(detail):
            "Failed to replace original file: \(detail)"
        }
    }
}
