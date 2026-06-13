import Foundation
import Testing

@testable import LibAVKit

/// Regression tests for codec drain at EOF.
///
/// When the demuxer is exhausted, codecs with decoder delay (MP3, AAC) still
/// hold buffered frames internally. The decoder must switch the codec to drain
/// mode and deliver those frames before throwing `endOfFile` — otherwise the
/// tail of every file is silently dropped from playback and conversion.
@Suite struct DecoderDrainTests {
    private func fixtureURL(_ relativePath: String) throws -> URL {
        let resourceURL = try #require(Bundle.module.resourceURL)
        return resourceURL
            .appendingPathComponent("Fixtures/Parametric")
            .appendingPathComponent(relativePath)
    }

    @Test(arguments: [
        "mp3/cd-stereo.mp3",
        "aac/cd-stereo.m4a",
        "flac/cd-16bit-stereo.flac",
        "opus/cd-stereo.opus",
        "vorbis/cd-stereo.ogg",
        "alac/cd-16bit-stereo.m4a",
    ])
    func decodeNextFrameDeliversFullDuration(_ fixture: String) throws {
        let decoder = Decoder()
        try decoder.open(url: fixtureURL(fixture))
        defer { decoder.close() }

        // Decoded frames are produced at the configured output rate, which can
        // differ from the source rate (e.g., 48kHz Opus resampled to 44.1kHz)
        let outputRate = decoder.configuredOutputFormat.sampleRate
        let expectedSamples = Int(decoder.duration * outputRate)
        var decodedSamples = 0

        while true {
            do {
                try decoder.decodeNextFrame { frame in
                    decodedSamples += frame.frameCount
                }
            } catch DecoderError.endOfFile {
                break
            }
        }

        // Tolerance covers container duration rounding and codec pre-skip
        // (Opus pre-skip is counted in container duration but trimmed from
        // decoded output). A missing codec drain would lose at least one full
        // codec frame (1152 samples for MP3), which stays detectable.
        #expect(
            decodedSamples >= expectedSamples - 1024,
            "Decoded \(decodedSamples) samples but expected ~\(expectedSamples) for \(fixture) — tail frames lost"
        )
    }
}
