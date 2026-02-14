import Foundation
import LibAVKit

/// Shared mutable state for BDD step definitions within a single scenario.
/// Reset per-scenario via `SetupSteps.init()`.
///
/// Safe because BDD tests run `.serialized` and step handlers run `@MainActor`.
final class TestContext: @unchecked Sendable {
    nonisolated(unsafe) static var shared = TestContext()

    var fixtureDir: URL?
    var workingCopy: URL?
    var tempDir: TemporaryDirectory?
    var outputURL: URL?
    var outputMetadata: AudioMetadata?
    var coverArtData: Data?
    var writeError: (any Error)?

    // Raw encoding
    var rawSamples: [[Float]]?
    var rawSampleRate: Int?
    var rawMetadata: AudioMetadata?

    // Playback
    var player: AudioPlayer?
    var playbackError: (any Error)?
    var stateTransitions: [PlaybackState] = []

    func reset() {
        player?.stop()
        player?.close()

        fixtureDir = nil
        workingCopy = nil
        tempDir = nil
        outputURL = nil
        outputMetadata = nil
        coverArtData = nil
        writeError = nil
        rawSamples = nil
        rawSampleRate = nil
        rawMetadata = nil
        player = nil
        playbackError = nil
        stateTransitions = []
    }
}
