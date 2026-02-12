import Foundation
import Testing

@testable import LibAVKit

// MARK: - Model Tests

@Test func outputFormatFileExtensions() {
    #expect(OutputFormat.flac.fileExtension == "flac")
    #expect(OutputFormat.alac.fileExtension == "m4a")
    #expect(OutputFormat.wav.fileExtension == "wav")
    #expect(OutputFormat.aiff.fileExtension == "aiff")
    #expect(OutputFormat.mp3.fileExtension == "mp3")
    #expect(OutputFormat.aac.fileExtension == "m4a")
    #expect(OutputFormat.opus.fileExtension == "opus")
    #expect(OutputFormat.vorbis.fileExtension == "ogg")
    #expect(OutputFormat.wavpack.fileExtension == "wv")
}

@Test func outputFormatLosslessFlag() {
    #expect(OutputFormat.flac.isLossless == true)
    #expect(OutputFormat.alac.isLossless == true)
    #expect(OutputFormat.wav.isLossless == true)
    #expect(OutputFormat.mp3.isLossless == false)
    #expect(OutputFormat.opus.isLossless == false)
}

@Test func outputFormatOggContainer() {
    #expect(OutputFormat.opus.usesOggContainer == true)
    #expect(OutputFormat.vorbis.usesOggContainer == true)
    #expect(OutputFormat.flac.usesOggContainer == false)
    #expect(OutputFormat.mp3.usesOggContainer == false)
}

@Test func outputFormatCoverArtSupport() {
    #expect(OutputFormat.flac.supportsCoverArt == true)
    #expect(OutputFormat.mp3.supportsCoverArt == true)
    #expect(OutputFormat.opus.supportsCoverArt == true)
    #expect(OutputFormat.wav.supportsCoverArt == false)
    #expect(OutputFormat.wavpack.supportsCoverArt == false)
}

@Test func encodingSettingsCodableRoundTrip() throws {
    let settings: [EncodingSettings] = [
        .flac(FLACEncodingSettings(compressionLevel: 8)),
        .mp3(MP3EncodingSettings(bitrateMode: .cbr, bitrateKbps: 320, vbrQuality: 2)),
        .aac(AACEncodingSettings(profile: .heV1, bitrateKbps: 128)),
        .opus(OpusEncodingSettings(bitrateKbps: 96)),
        .vorbis(VorbisEncodingSettings(quality: 7)),
        .lossless,
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for setting in settings {
        let data = try encoder.encode(setting)
        let decoded = try decoder.decode(EncodingSettings.self, from: data)
        #expect(decoded == setting)
    }
}

@Test func encodingSettingsDefaults() {
    #expect(EncodingSettings.defaults(for: .flac) == .flac(FLACEncodingSettings()))
    #expect(EncodingSettings.defaults(for: .mp3) == .mp3(MP3EncodingSettings()))
    #expect(EncodingSettings.defaults(for: .alac) == .lossless)
    #expect(EncodingSettings.defaults(for: .wav) == .lossless)
}

@Test func metadataChangesIsEmpty() {
    #expect(MetadataChanges().isEmpty == true)
    #expect(MetadataChanges(title: "Test").isEmpty == false)
    #expect(MetadataChanges(year: 2024).isEmpty == false)
}

@Test func audioOutputFormatDescription() {
    let format = AudioOutputFormat(sampleRate: 44100, channelCount: 2, sampleFormat: .float32)
    #expect(format.description == "44.1kHz/32-bit/2ch")

    let hiRes = AudioOutputFormat(sampleRate: 96000, channelCount: 2, sampleFormat: .int24)
    #expect(hiRes.description == "96kHz/24-bit/2ch")
}

@Test func audioSampleFormatBytesPerSample() {
    #expect(AudioSampleFormat.int16.bytesPerSample == 2)
    #expect(AudioSampleFormat.int24.bytesPerSample == 3)
    #expect(AudioSampleFormat.int32.bytesPerSample == 4)
    #expect(AudioSampleFormat.float32.bytesPerSample == 4)
    #expect(AudioSampleFormat.float64.bytesPerSample == 8)
}

// MARK: - VorbisPictureBlock Tests

@Test func vorbisPictureBlockReturnsNilForEmptyData() {
    #expect(VorbisPictureBlock.base64Encoded(imageData: Data()) == nil)
}

@Test func vorbisPictureBlockDetectsMIMEType() {
    // PNG magic bytes
    let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x00])
    #expect(VorbisPictureBlock.detectMIMEType(pngData) == "image/png")

    // JPEG magic bytes
    let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
    #expect(VorbisPictureBlock.detectMIMEType(jpegData) == "image/jpeg")
}

// MARK: - CustomTagParser Tests

@Test func customTagParserParsesEquals() {
    let result = CustomTagParser.parse("ARTIST=John Doe")
    #expect(result?.key == "ARTIST")
    #expect(result?.value == "John Doe")
}

@Test func customTagParserParsesColon() {
    let result = CustomTagParser.parse("ARTIST:John Doe")
    #expect(result?.key == "ARTIST")
    #expect(result?.value == "John Doe")
}

@Test func customTagParserReturnsNilForInvalid() {
    #expect(CustomTagParser.parse("no separator here") == nil)
    #expect(CustomTagParser.parse("=value") == nil)
    #expect(CustomTagParser.parse("key=") == nil)
}

// MARK: - FFmpeg Runtime Tests

@Test func ffmpegEncoderAvailability() {
    // FLAC should always be available
    #expect(Encoder.isEncoderAvailable(for: .flac) == true)
}

@Test func metadataReaderThrowsForMissingFile() {
    let reader = MetadataReader()
    #expect(throws: DecoderError.self) {
        try reader.read(url: URL(fileURLWithPath: "/nonexistent/file.flac"))
    }
}
