import CFFmpeg
import Foundation

public final class MetadataReader: @unchecked Sendable {
    public init() {}

    public func read(url: URL) throws -> AudioMetadata {
        var metadata = AudioMetadata()

        var formatContext: UnsafeMutablePointer<AVFormatContext>?

        guard avformat_open_input(&formatContext, url.path, nil, nil) == 0 else {
            throw DecoderError.openFailed(url.path)
        }

        defer {
            avformat_close_input(&formatContext)
        }

        guard avformat_find_stream_info(formatContext, nil) >= 0 else {
            throw DecoderError.streamInfoNotFound
        }

        // Find audio stream for codec info
        var audioStreamIndex: Int32 = -1
        for i in 0 ..< Int32(formatContext!.pointee.nb_streams) {
            let stream = formatContext!.pointee.streams[Int(i)]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                audioStreamIndex = i
                break
            }
        }

        if audioStreamIndex >= 0 {
            let stream = formatContext!.pointee.streams[Int(audioStreamIndex)]!
            let codecPar = stream.pointee.codecpar!

            // Duration
            let timeBase = stream.pointee.time_base
            if stream.pointee.duration != Int64(AV_NOPTS_VALUE) {
                metadata.duration = Double(stream.pointee.duration) * av_q2d(timeBase)
            } else if formatContext!.pointee.duration != Int64(AV_NOPTS_VALUE) {
                metadata.duration = Double(formatContext!.pointee.duration) / Double(AV_TIME_BASE)
            }

            // Codec info with Dolby Atmos detection
            let codecId = codecPar.pointee.codec_id
            let baseCodecName = String(cString: avcodec_get_name(codecId))

            // Check for E-AC-3 (Dolby Digital Plus) - may contain Atmos
            if harmonica_is_eac3(codecId) != 0 {
                // Need to check codec profile for Atmos (JOC)
                // Open decoder to get profile information
                let codec = avcodec_find_decoder(codecId)
                var codecContext = avcodec_alloc_context3(codec)
                defer { avcodec_free_context(&codecContext) }

                if codecContext != nil {
                    avcodec_parameters_to_context(codecContext, codecPar)
                    if avcodec_open2(codecContext, codec, nil) == 0 {
                        let profile = codecContext!.pointee.profile
                        if profile == harmonica_get_eac3_atmos_profile() {
                            metadata.codec = "eac3_atmos"
                            metadata.isAtmos = true
                        } else {
                            metadata.codec = "eac3"
                        }
                    } else {
                        metadata.codec = "eac3"
                    }
                } else {
                    metadata.codec = "eac3"
                }
            }
            // Check for TrueHD - may contain Atmos (requires bitstream parsing)
            else if harmonica_is_truehd(codecId) != 0 {
                // TrueHD Atmos detection would require parsing MLP headers
                // For now, mark as truehd - Atmos substream detection is complex
                metadata.codec = "truehd"
            } else {
                metadata.codec = baseCodecName
            }
            // Try codec-level bitrate first, fall back to format-level for VBR files
            let codecBitrate = Int(codecPar.pointee.bit_rate)
            let formatBitrate = Int(formatContext!.pointee.bit_rate)
            let bitrate = codecBitrate > 0 ? codecBitrate : formatBitrate
            if bitrate > 0 {
                metadata.bitrate = bitrate
            }
            let sampleRate = Int(codecPar.pointee.sample_rate)
            if sampleRate > 0 {
                metadata.sampleRate = sampleRate
            }
            // bits_per_raw_sample is the actual bit depth for lossless formats
            // bits_per_coded_sample is used for some formats when raw is unavailable
            let bitsPerRaw = Int(codecPar.pointee.bits_per_raw_sample)
            let bitsPerCoded = Int(codecPar.pointee.bits_per_coded_sample)
            let bitDepth = bitsPerRaw > 0 ? bitsPerRaw : bitsPerCoded
            if bitDepth > 0 {
                metadata.bitDepth = bitDepth
            }
            let channels = Int(codecPar.pointee.ch_layout.nb_channels)
            if channels > 0 {
                metadata.channels = channels
            }
        }

        // Extract embedded album art (attached picture)
        for i in 0 ..< Int32(formatContext!.pointee.nb_streams) {
            let stream = formatContext!.pointee.streams[Int(i)]!
            let disposition = stream.pointee.disposition

            // Check if this stream is an attached picture (AV_DISPOSITION_ATTACHED_PIC = 0x0400)
            if (disposition & AV_DISPOSITION_ATTACHED_PIC) != 0 {
                let attachedPic = stream.pointee.attached_pic
                if attachedPic.size > 0, let data = attachedPic.data {
                    metadata.coverArt = Data(bytes: data, count: Int(attachedPic.size))
                }
                break
            }
        }

        // Determine metadata source by container format.
        // OGG demuxer stores Vorbis comments on the audio stream; all others use format context.
        let metadataDict: OpaquePointer? = if let iformat = formatContext!.pointee.iformat,
                                              String(cString: iformat.pointee.name) == "ogg",
                                              audioStreamIndex >= 0 {
            formatContext!.pointee.streams[Int(audioStreamIndex)]!.pointee.metadata
        } else {
            formatContext!.pointee.metadata
        }

        metadata.title = readTag("title", from: metadataDict)
        metadata.artist = readTag("artist", from: metadataDict)
        metadata.album = readTag("album", from: metadataDict)
        metadata.albumArtist = readTag("album_artist", from: metadataDict)
        metadata.genre = readTag("genre", from: metadataDict)

        if let dateStr = readTag("date", from: metadataDict),
           let year = Int(dateStr.prefix(4)) {
            metadata.year = year
        }

        if let trackStr = readTag("track", from: metadataDict) {
            let parts = trackStr.split(separator: "/")
            if let trackNum = Int(parts.first ?? "") {
                metadata.trackNumber = trackNum
            }
        }

        if let discStr = readTag("disc", from: metadataDict) {
            let parts = discStr.split(separator: "/")
            if let discNum = Int(parts.first ?? "") {
                metadata.discNumber = discNum
            }
        }

        return metadata
    }

    private func readTag(_ key: String, from dict: OpaquePointer?) -> String? {
        guard let tag = av_dict_get(dict, key, nil, 0),
              let value = tag.pointee.value else { return nil }
        return String(cString: value)
    }
}

private let AV_NOPTS_VALUE: Int64 = .init(bitPattern: 0x8000_0000_0000_0000)
