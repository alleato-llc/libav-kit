import Foundation
import Testing

@testable import LibAVKit

/// Tests for the `ioTimeout` interrupt mechanism that bounds blocking reads on
/// network sources (NAS/SMB). A genuinely hung read can't be reproduced
/// deterministically in a unit test, so these guard the surrounding contract:
/// the timeout is off by default, and arming it must not falsely abort a normal
/// (fast, local) decode.
@Suite struct DecoderIOTimeoutTests {
    private func fixtureURL(_ relativePath: String) throws -> URL {
        let resourceURL = try #require(Bundle.module.resourceURL)
        return resourceURL
            .appendingPathComponent("Fixtures/Parametric")
            .appendingPathComponent(relativePath)
    }

    @Test func ioTimeoutIsDisabledByDefault() {
        #expect(Decoder().ioTimeout == 0, "Timeout must default off to preserve blocking behavior for local files")
    }

    @Test(arguments: [
        "flac/cd-16bit-stereo.flac",
        "mp3/cd-stereo.mp3",
        "opus/cd-stereo.opus"
    ])
    func nonZeroTimeoutDoesNotFalseTriggerOnLocalDecode(_ fixture: String) throws {
        let decoder = Decoder()
        decoder.ioTimeout = 5.0
        try decoder.open(url: fixtureURL(fixture))
        defer { decoder.close() }

        // A fast local decode must run to EOF without the deadline aborting a read.
        // Any spurious abort surfaces as readTimedOut (or decodeFailed), failing here.
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

        #expect(decodedSamples > 0, "Decode with a timeout armed produced no audio for \(fixture)")
    }
}
