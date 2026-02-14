import Foundation
import LibAVKit
import PickleKit
import Testing

/// Step definitions for raw encoding scenarios (encode from programmatic samples).
struct RawEncodingSteps: StepDefinitions {
    init() {}

    // MARK: - Given

    /// Given a 440Hz sine wave at 44100Hz sample rate for 1 second with 1 channel
    let givenSineWave = StepDefinition.given(
        #"a (\d+)Hz sine wave at (\d+)Hz sample rate for (\d+) seconds? with (\d+) channels?"#
    ) { match in
        let frequency = Double(match.captures[0])!
        let sampleRate = Int(match.captures[1])!
        let duration = Double(match.captures[2])!
        let channels = Int(match.captures[3])!

        let ctx = TestContext.shared
        ctx.rawSamples = SineWaveGenerator.generate(
            frequency: frequency, sampleRate: sampleRate,
            duration: duration, channels: channels
        )
        ctx.rawSampleRate = sampleRate
    }

    /// Given metadata with title "Test Tone" and artist "Generator"
    let givenRawMetadata = StepDefinition.given(
        #"metadata with title "([^"]+)" and artist "([^"]+)""#
    ) { match in
        let ctx = TestContext.shared
        var metadata = AudioMetadata()
        metadata.title = match.captures[0]
        metadata.artist = match.captures[1]
        ctx.rawMetadata = metadata
    }

    // MARK: - When

    /// When I encode the raw samples to FLAC at the output path
    let whenEncodeRaw = StepDefinition.when(
        #"I encode the raw samples to FLAC at the output path"#
    ) { _ in
        let ctx = TestContext.shared
        guard let samples = ctx.rawSamples else {
            throw StepError.assertion("No raw samples generated")
        }
        guard let sampleRate = ctx.rawSampleRate else {
            throw StepError.assertion("No sample rate set")
        }
        guard let tempDir = ctx.tempDir else {
            throw StepError.assertion("No temp directory set")
        }

        let outputURL = tempDir.url
            .appendingPathComponent("raw-output-\(UUID().uuidString)")
            .appendingPathExtension("flac")

        let config = ConversionConfig(
            outputFormat: .flac,
            encodingSettings: .defaults(for: .flac),
            destination: .folder(tempDir.url, template: nil)
        )

        let encoder = Encoder()
        try encoder.encode(
            samples: samples,
            sampleRate: sampleRate,
            outputURL: outputURL,
            config: config,
            metadata: ctx.rawMetadata
        )

        ctx.outputURL = outputURL
        ctx.outputMetadata = try MetadataReader().read(url: outputURL)
    }

    // MARK: - Then

    /// Then the output has codec "flac"
    let thenOutputCodec = StepDefinition.then(
        #"the output has codec "([^"]+)""#
    ) { match in
        let expected = match.captures[0]
        let metadata = try requireOutputMetadata()
        guard metadata.codec.lowercased() == expected.lowercased() else {
            throw StepError.assertion(
                "Expected codec '\(expected)', got '\(metadata.codec)'"
            )
        }
    }

    /// Then the output has sample rate 44100
    let thenOutputSampleRate = StepDefinition.then(
        #"the output has sample rate (\d+)"#
    ) { match in
        let expected = Int(match.captures[0])!
        let metadata = try requireOutputMetadata()
        guard metadata.sampleRate == expected else {
            throw StepError.assertion(
                "Expected sample rate \(expected), got \(metadata.sampleRate ?? -1)"
            )
        }
    }

    /// Then the output has N channel(s)
    let thenOutputChannels = StepDefinition.then(
        #"the output has (\d+) channels?"#
    ) { match in
        let expected = Int(match.captures[0])!
        let metadata = try requireOutputMetadata()
        guard metadata.channels == expected else {
            throw StepError.assertion(
                "Expected \(expected) channel(s), got \(metadata.channels ?? -1)"
            )
        }
    }

    /// Then the output duration is approximately N.N seconds
    let thenOutputDuration = StepDefinition.then(
        #"the output duration is approximately ([\d.]+) seconds?"#
    ) { match in
        let expected = Double(match.captures[0])!
        let metadata = try requireOutputMetadata()
        let tolerance = 0.1
        guard abs(metadata.duration - expected) < tolerance else {
            throw StepError.assertion(
                "Expected duration ~\(expected)s, got \(metadata.duration)s"
            )
        }
    }

    /// Then the output metadata title is "..."
    let thenOutputTitle = StepDefinition.then(
        #"the output metadata title is "([^"]+)""#
    ) { match in
        let expected = match.captures[0]
        let metadata = try requireOutputMetadata()
        guard metadata.title == expected else {
            throw StepError.assertion(
                "Expected title '\(expected)', got '\(metadata.title ?? "nil")'"
            )
        }
    }

    /// Then the output metadata artist is "..."
    let thenOutputArtist = StepDefinition.then(
        #"the output metadata artist is "([^"]+)""#
    ) { match in
        let expected = match.captures[0]
        let metadata = try requireOutputMetadata()
        guard metadata.artist == expected else {
            throw StepError.assertion(
                "Expected artist '\(expected)', got '\(metadata.artist ?? "nil")'"
            )
        }
    }
}

private func requireOutputMetadata() throws -> AudioMetadata {
    guard let metadata = TestContext.shared.outputMetadata else {
        throw StepError.assertion("No output metadata available")
    }
    return metadata
}
