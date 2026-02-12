import CFFmpeg

// MARK: - Codec Mapping

extension Encoder {
    struct EncoderSpec {
        let codecId: AVCodecID
        let encoderName: String?
        let containerFormat: String

        init(codecId: AVCodecID, encoderName: String? = nil, containerFormat: String) {
            self.codecId = codecId
            self.encoderName = encoderName
            self.containerFormat = containerFormat
        }
    }

    func encoderSpec(for format: OutputFormat, bitDepth: Int? = nil) -> EncoderSpec {
        switch format {
        case .flac:
            EncoderSpec(codecId: AV_CODEC_ID_FLAC, containerFormat: "flac")
        case .alac:
            EncoderSpec(codecId: AV_CODEC_ID_ALAC, containerFormat: "ipod")
        case .wav:
            EncoderSpec(codecId: pcmCodecForWAV(bitDepth: bitDepth), containerFormat: "wav")
        case .aiff:
            EncoderSpec(codecId: pcmCodecForAIFF(bitDepth: bitDepth), containerFormat: "aiff")
        case .wavpack:
            EncoderSpec(codecId: AV_CODEC_ID_WAVPACK, containerFormat: "wv")
        case .mp3:
            EncoderSpec(codecId: AV_CODEC_ID_MP3, encoderName: "libmp3lame", containerFormat: "mp3")
        case .aac:
            EncoderSpec(codecId: AV_CODEC_ID_AAC, encoderName: preferredAACEncoder(), containerFormat: "ipod")
        case .opus:
            EncoderSpec(codecId: AV_CODEC_ID_OPUS, encoderName: "libopus", containerFormat: "ogg")
        case .vorbis:
            EncoderSpec(codecId: AV_CODEC_ID_VORBIS, encoderName: "libvorbis", containerFormat: "ogg")
        }
    }

    private func pcmCodecForWAV(bitDepth: Int?) -> AVCodecID {
        switch bitDepth {
        case 24: AV_CODEC_ID_PCM_S24LE
        case 32: AV_CODEC_ID_PCM_S32LE
        default: AV_CODEC_ID_PCM_S16LE
        }
    }

    private func pcmCodecForAIFF(bitDepth: Int?) -> AVCodecID {
        switch bitDepth {
        case 24: AV_CODEC_ID_PCM_S24BE
        case 32: AV_CODEC_ID_PCM_S32BE
        default: AV_CODEC_ID_PCM_S16BE
        }
    }

    /// Tries AAC encoders in preference order: libfdk_aac (best quality) > aac_at (Apple AudioToolbox) > native aac
    private func preferredAACEncoder() -> String? {
        let preferred = ["libfdk_aac", "aac_at"]
        for name in preferred {
            if avcodec_find_encoder_by_name(name) != nil {
                return name
            }
        }
        return nil // Falls back to avcodec_find_encoder(AV_CODEC_ID_AAC)
    }

    /// Returns the name of the currently selected AAC encoder
    public func selectedAACEncoderName() -> String {
        if let preferred = preferredAACEncoder() {
            return preferred
        }
        if let enc = avcodec_find_encoder(AV_CODEC_ID_AAC) {
            return String(cString: enc.pointee.name)
        }
        return "aac"
    }
}

// MARK: - Bitrate Configuration

extension Encoder {
    func configureBitrate(
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        config: ConversionConfig,
        format _: OutputFormat
    ) {
        switch config.encodingSettings {
        case let .mp3(settings):
            configureMP3Bitrate(encCtx: encCtx, settings: settings)
        case let .aac(settings):
            configureAACBitrate(encCtx: encCtx, settings: settings)
        case let .opus(settings):
            encCtx.pointee.bit_rate = Int64(settings.bitrateKbps * 1000)
        case let .vorbis(settings):
            av_opt_set_int(encCtx.pointee.priv_data, "qscale", Int64(settings.quality), 0)
        case let .flac(settings):
            encCtx.pointee.compression_level = Int32(settings.compressionLevel)
        case .lossless:
            break
        }
    }

    private func configureMP3Bitrate(
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        settings: MP3EncodingSettings
    ) {
        switch settings.bitrateMode {
        case .cbr:
            encCtx.pointee.bit_rate = Int64(settings.bitrateKbps * 1000)
        case .vbr:
            av_opt_set_int(encCtx.pointee.priv_data, "qscale", Int64(settings.vbrQuality), 0)
        case .abr:
            encCtx.pointee.bit_rate = Int64(settings.bitrateKbps * 1000)
            av_opt_set(encCtx.pointee.priv_data, "abr", "1", 0)
        }
    }

    private func configureAACBitrate(
        encCtx: UnsafeMutablePointer<AVCodecContext>,
        settings: AACEncodingSettings
    ) {
        encCtx.pointee.bit_rate = Int64(settings.bitrateKbps * 1000)
        switch settings.profile {
        case .lc:
            encCtx.pointee.profile = 0 // FF_PROFILE_AAC_LOW
        case .heV1:
            encCtx.pointee.profile = 4 // FF_PROFILE_AAC_HE
        case .heV2:
            encCtx.pointee.profile = 28 // FF_PROFILE_AAC_HE_V2
        }
    }
}
