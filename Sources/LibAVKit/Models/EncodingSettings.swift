import Foundation

// MARK: - Per-Codec Settings

public struct FLACEncodingSettings: Sendable, Equatable, Codable {
    public var compressionLevel: Int // 0-8, default 5

    public init(compressionLevel: Int = 5) {
        self.compressionLevel = compressionLevel
    }
}

public struct MP3EncodingSettings: Sendable, Equatable, Codable {
    public var bitrateMode: BitrateMode
    public var bitrateKbps: Int
    public var vbrQuality: Int // 0=best, 9=smallest

    public init(bitrateMode: BitrateMode = .vbr, bitrateKbps: Int = 320, vbrQuality: Int = 2) {
        self.bitrateMode = bitrateMode
        self.bitrateKbps = bitrateKbps
        self.vbrQuality = vbrQuality
    }
}

public struct AACEncodingSettings: Sendable, Equatable, Codable {
    public var profile: AACProfile
    public var bitrateKbps: Int

    public init(profile: AACProfile = .lc, bitrateKbps: Int = 256) {
        self.profile = profile
        self.bitrateKbps = bitrateKbps
    }
}

public struct OpusEncodingSettings: Sendable, Equatable, Codable {
    public var bitrateKbps: Int

    public init(bitrateKbps: Int = 128) {
        self.bitrateKbps = bitrateKbps
    }
}

public struct VorbisEncodingSettings: Sendable, Equatable, Codable {
    public var quality: Int // 0-10, default 5

    public init(quality: Int = 5) {
        self.quality = quality
    }
}

// MARK: - Polymorphic EncodingSettings Enum

public enum EncodingSettings: Sendable, Equatable {
    case flac(FLACEncodingSettings)
    case mp3(MP3EncodingSettings)
    case aac(AACEncodingSettings)
    case opus(OpusEncodingSettings)
    case vorbis(VorbisEncodingSettings)
    case lossless // ALAC, WAV, AIFF, WavPack — no configurable settings
}

// MARK: - Codable (discriminator-based)

extension EncodingSettings: Codable {
    private enum SettingsType: String, Codable {
        case flac, mp3, aac, opus, vorbis, lossless
    }

    private enum CodingKeys: String, CodingKey {
        case type, settings
    }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SettingsType.self, forKey: .type)
        switch type {
        case .flac:
            self = try .flac(container.decode(FLACEncodingSettings.self, forKey: .settings))
        case .mp3:
            self = try .mp3(container.decode(MP3EncodingSettings.self, forKey: .settings))
        case .aac:
            self = try .aac(container.decode(AACEncodingSettings.self, forKey: .settings))
        case .opus:
            self = try .opus(container.decode(OpusEncodingSettings.self, forKey: .settings))
        case .vorbis:
            self = try .vorbis(container.decode(VorbisEncodingSettings.self, forKey: .settings))
        case .lossless:
            self = .lossless
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .flac(s):
            try container.encode(SettingsType.flac, forKey: .type)
            try container.encode(s, forKey: .settings)
        case let .mp3(s):
            try container.encode(SettingsType.mp3, forKey: .type)
            try container.encode(s, forKey: .settings)
        case let .aac(s):
            try container.encode(SettingsType.aac, forKey: .type)
            try container.encode(s, forKey: .settings)
        case let .opus(s):
            try container.encode(SettingsType.opus, forKey: .type)
            try container.encode(s, forKey: .settings)
        case let .vorbis(s):
            try container.encode(SettingsType.vorbis, forKey: .type)
            try container.encode(s, forKey: .settings)
        case .lossless:
            try container.encode(SettingsType.lossless, forKey: .type)
        }
    }
}

// MARK: - Factory

public extension EncodingSettings {
    /// Returns the default encoding settings for the given output format.
    static func defaults(for format: OutputFormat) -> EncodingSettings {
        switch format {
        case .flac: .flac(FLACEncodingSettings())
        case .mp3: .mp3(MP3EncodingSettings())
        case .aac: .aac(AACEncodingSettings())
        case .opus: .opus(OpusEncodingSettings())
        case .vorbis: .vorbis(VorbisEncodingSettings())
        case .alac, .wav, .aiff, .wavpack: .lossless
        }
    }
}
