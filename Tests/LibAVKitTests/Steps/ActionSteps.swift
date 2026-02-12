import Foundation
import LibAVKit
import PickleKit

/// When steps — execute encoding, embedding, metadata writing actions.
struct ActionSteps: StepDefinitions {
    init() {}

    // MARK: - Encoding

    /// When I encode it to "<format>" with settings "<settings>"
    let encodeBasic = StepDefinition.when(
        #"I encode it to "([^"]+)" with settings "([^"]+)""#
    ) { match in
        let formatStr = match.captures[0]
        let settingsKey = match.captures[1]
        try performEncode(formatStr: formatStr, settingsKey: settingsKey)
    }

    /// When I encode it to "<format>" with settings "<settings>" at sample rate <rate>
    let encodeWithSampleRate = StepDefinition.when(
        #"I encode it to "([^"]+)" with settings "([^"]+)" at sample rate (\d+)"#
    ) { match in
        let formatStr = match.captures[0]
        let settingsKey = match.captures[1]
        let sampleRate = Int(match.captures[2])
        try performEncode(formatStr: formatStr, settingsKey: settingsKey, sampleRate: sampleRate)
    }

    /// When I encode it to "<format>" with settings "<settings>" at bit depth <depth>
    let encodeWithBitDepth = StepDefinition.when(
        #"I encode it to "([^"]+)" with settings "([^"]+)" at bit depth (\d+)"#
    ) { match in
        let formatStr = match.captures[0]
        let settingsKey = match.captures[1]
        let bitDepth = Int(match.captures[2])
        try performEncode(formatStr: formatStr, settingsKey: settingsKey, bitDepth: bitDepth)
    }

    /// When I encode it to "<format>" with settings "<settings>" at sample rate <rate> and bit depth <depth>
    let encodeWithBoth = StepDefinition.when(
        #"I encode it to "([^"]+)" with settings "([^"]+)" at sample rate (\d+) and bit depth (\d+)"#
    ) { match in
        let formatStr = match.captures[0]
        let settingsKey = match.captures[1]
        let sampleRate = Int(match.captures[2])
        let bitDepth = Int(match.captures[3])
        try performEncode(
            formatStr: formatStr, settingsKey: settingsKey,
            sampleRate: sampleRate, bitDepth: bitDepth
        )
    }

    // MARK: - Cover Art

    /// When I embed the cover art
    let embedCoverArt = StepDefinition.when(
        #"I embed the cover art"#
    ) { _ in
        let ctx = TestContext.shared
        guard let workingCopy = ctx.workingCopy else {
            throw StepError.assertion("No working copy set")
        }
        guard let imageData = ctx.coverArtData else {
            throw StepError.assertion("No cover art data set")
        }

        let isOgg = workingCopy.pathExtension == "ogg" || workingCopy.pathExtension == "opus"
        let embedder = CoverArtEmbedder()
        try embedder.embed(in: workingCopy, imageData: imageData, isOggContainer: isOgg)
    }

    /// When I remove the cover art
    let removeCoverArt = StepDefinition.when(
        #"I remove the cover art"#
    ) { _ in
        let ctx = TestContext.shared
        guard let workingCopy = ctx.workingCopy else {
            throw StepError.assertion("No working copy set")
        }

        let embedder = CoverArtEmbedder()
        try embedder.remove(from: workingCopy)
    }

    // MARK: - Metadata Writing

    /// When I write metadata with title "..." artist "..." album "..." track N disc N genre "..." year N
    let writeMetadata = StepDefinition.when(
        #"I write metadata with title "([^"]+)" artist "([^"]+)" album "([^"]+)" track (\d+) disc (\d+) genre "([^"]+)" year (\d+)"#
    ) { match in
        let ctx = TestContext.shared
        guard let workingCopy = ctx.workingCopy else {
            throw StepError.assertion("No working copy set")
        }

        let changes = MetadataChanges(
            title: match.captures[0],
            artistName: match.captures[1],
            albumTitle: match.captures[2],
            trackNumber: Int(match.captures[3]),
            discNumber: Int(match.captures[4]),
            genre: match.captures[5],
            year: Int(match.captures[6])
        )

        let writer = TagWriter()
        try writer.write(to: workingCopy, changes: changes)
    }

    /// When I attempt to write metadata (error path)
    let attemptWriteMetadata = StepDefinition.when(
        #"I attempt to write metadata"#
    ) { _ in
        let ctx = TestContext.shared
        guard let workingCopy = ctx.workingCopy else {
            throw StepError.assertion("No working copy set")
        }

        let changes = MetadataChanges(title: "Test")
        let writer = TagWriter()

        do {
            try writer.write(to: workingCopy, changes: changes)
        } catch {
            ctx.writeError = error
        }
    }
}

// MARK: - Helpers

private func performEncode(
    formatStr: String,
    settingsKey: String,
    sampleRate: Int? = nil,
    bitDepth: Int? = nil
) throws {
    let ctx = TestContext.shared
    guard let inputURL = ctx.workingCopy else {
        throw StepError.assertion("No working copy set")
    }
    guard let tempDir = ctx.tempDir else {
        throw StepError.assertion("No temp directory set")
    }

    let outputFormat = resolveOutputFormat(formatStr)
    let encodingSettings = EncodingSettingsResolver.resolve(settingsKey)

    let outputURL = tempDir.url
        .appendingPathComponent("output-\(UUID().uuidString)")
        .appendingPathExtension(outputFormat.fileExtension)

    let reader = MetadataReader()
    let sourceMetadata = try reader.read(url: inputURL)

    let config = ConversionConfig(
        outputFormat: outputFormat,
        encodingSettings: encodingSettings,
        sampleRate: sampleRate,
        bitDepth: bitDepth,
        destination: .folder(tempDir.url, template: nil)
    )

    let encoder = Encoder()
    try encoder.encode(
        inputURL: inputURL,
        outputURL: outputURL,
        config: config,
        metadata: sourceMetadata,
        progress: { _ in },
        isCancelled: { false }
    )

    ctx.outputURL = outputURL

    // Read output metadata for verification steps
    ctx.outputMetadata = try reader.read(url: outputURL)
}

private func resolveOutputFormat(_ str: String) -> OutputFormat {
    switch str.lowercased() {
    case "flac": return .flac
    case "alac": return .alac
    case "wav": return .wav
    case "aiff": return .aiff
    case "wavpack": return .wavpack
    case "mp3": return .mp3
    case "aac": return .aac
    case "opus": return .opus
    case "vorbis": return .vorbis
    default: fatalError("Unknown output format: \(str)")
    }
}
