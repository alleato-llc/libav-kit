import ArgumentParser
import Foundation
import LibAVKit

@main
struct LibAVPlay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "libav-play",
        abstract: "Play audio files using LibAVKit.",
        discussion: """
        File mode:  libav-play song.flac
        STDIN mode: cat song.flac | libav-play --format flac -
        """
    )

    @Argument(help: "Audio file path, or \"-\" to read from STDIN.")
    var file: String?

    @Option(help: "Playback volume (0.0–1.0).")
    var volume: Float = 1.0

    @Option(help: "Format hint for STDIN (e.g. flac, mp3, opus). Required when reading from STDIN.")
    var format: String?

    func run() throws {
        let isSTDIN = file == "-" || (file == nil && !isatty(STDIN_FILENO).boolValue)

        if isSTDIN {
            try runSTDINMode()
        } else if let file {
            try runFileMode(path: file)
        } else {
            print("No file specified. Use --help for usage.")
            throw ExitCode.failure
        }
    }

    // MARK: - File Mode (AudioPlayer)

    private func runFileMode(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            print("File not found: \(path)")
            throw ExitCode.failure
        }

        let player = AudioPlayer()

        // Set up signal handling for Ctrl+C
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigSource.setEventHandler {
            print("\nStopping playback...")
            player.stop()
            LibAVPlay.exit()
        }
        sigSource.resume()

        do {
            try player.open(url: url)
        } catch {
            print("Failed to open file: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        player.volume = volume
        printMetadata(player.metadata, duration: player.duration, sampleRate: player.sampleRate, channels: player.channels)

        player.onProgress = { time in
            let pct = player.duration > 0 ? time / player.duration * 100 : 0
            print("\r  \(formatTime(time)) / \(formatTime(player.duration))  [\(String(format: "%.0f", pct))%]", terminator: "")
            fflush(stdout)
        }

        player.onStateChange = { state in
            if state == .completed {
                print("\nPlayback complete.")
                LibAVPlay.exit()
            }
        }

        player.onError = { error in
            print("\nPlayback error: \(error)")
            LibAVPlay.exit(withError: ExitCode.failure)
        }

        player.play()
        dispatchMain()
    }

    // MARK: - STDIN Mode (Decoder + AVAudioEngineOutput)

    private func runSTDINMode() throws {
        guard let format else {
            print("--format is required when reading from STDIN.")
            throw ExitCode.failure
        }

        let decoder = Decoder()
        do {
            try decoder.open(path: "pipe:0", inputFormat: format)
        } catch {
            print("Failed to open STDIN: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // Reconfigure decoder to match source format for playback
        guard let sourceFormat = decoder.sourceFormat else {
            print("Could not detect source format from STDIN.")
            throw ExitCode.failure
        }
        let outputFormat = AudioOutputFormat(
            sampleRate: sourceFormat.sampleRate,
            channelCount: sourceFormat.channelCount,
            sampleFormat: .float32,
            isInterleaved: false
        )
        try decoder.reconfigure(outputFormat: outputFormat)

        print("STDIN mode (\(format)): \(decoder.sampleRate) Hz, \(decoder.channels) ch, \(decoder.codecName)")

        let output = AVAudioEngineOutput()
        try output.configure(sampleRate: Double(decoder.sampleRate), channels: decoder.channels)
        try output.start()
        output.volume = volume

        // Set up signal handling for Ctrl+C
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigSource.setEventHandler {
            print("\nStopping playback...")
            output.stop()
            decoder.close()
            LibAVPlay.exit()
        }
        sigSource.resume()

        // Decode loop on a background queue
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                while true {
                    try decoder.decodeNextFrame { frame in
                        output.scheduleAudio(frame)
                    }
                }
            } catch let error as DecoderError where error.isEndOfFile {
                // Wait for audio output to finish
                output.waitForCompletion { false }
                print("\nPlayback complete.")
                LibAVPlay.exit()
            } catch {
                print("\nDecode error: \(error.localizedDescription)")
                LibAVPlay.exit(withError: ExitCode.failure)
            }
        }

        dispatchMain()
    }
}

// MARK: - Helpers

private func printMetadata(_ meta: AudioMetadata, duration: TimeInterval, sampleRate: Int, channels: Int) {
    print("Now playing:")
    if let title = meta.title {
        print("  Title:  \(title)")
    }
    if let artist = meta.artist {
        print("  Artist: \(artist)")
    }
    if let album = meta.album {
        print("  Album:  \(album)")
    }
    if !meta.codec.isEmpty {
        print("  Codec:  \(meta.codec)")
    }
    print("  Format: \(sampleRate) Hz, \(channels) ch")
    if duration > 0 {
        print("  Length: \(formatTime(duration))")
    }
    print()
}

private func formatTime(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
}

private extension DecoderError {
    var isEndOfFile: Bool {
        if case .endOfFile = self { return true }
        return false
    }
}

private extension Int32 {
    var boolValue: Bool { self != 0 }
}
