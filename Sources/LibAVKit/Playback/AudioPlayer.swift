import Foundation

public final class AudioPlayer: @unchecked Sendable {
    // MARK: - Audio output

    private let output: AudioOutput

    // MARK: - Decoder

    private let decoder = Decoder()

    // MARK: - Concurrency

    private let queue = DispatchQueue(label: "com.libav-kit.audio-player", qos: .userInitiated)
    private let lock = NSLock()
    private var isDecoding = false
    private var stopRequested = false

    // MARK: - Read-only properties (available after open)

    public private(set) var metadata = AudioMetadata()
    public private(set) var duration: TimeInterval = 0
    public private(set) var sampleRate: Int = 0
    public private(set) var channels: Int = 0

    // MARK: - Observable state

    public private(set) var state: PlaybackState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// The current playback position in seconds.
    /// When playing, this is computed from the audio output's actual position.
    /// When paused/stopped/completed, this returns the last captured position.
    public var currentTime: TimeInterval {
        get {
            if state == .playing {
                return computePlaybackPosition()
            }
            return _currentTime
        }
        set {
            _currentTime = newValue
        }
    }

    private var _currentTime: TimeInterval = 0

    /// The time offset for the current playback segment (set on seek or play-from-start).
    private var seekBase: TimeInterval = 0

    public var volume: Float {
        get { output.volume }
        set { output.volume = max(0, min(1, newValue)) }
    }

    // MARK: - Closure callbacks

    public var onStateChange: (@Sendable (PlaybackState) -> Void)?
    public var onProgress: (@Sendable (TimeInterval) -> Void)?
    public var onError: (@Sendable (PlaybackError) -> Void)?

    // MARK: - Lifecycle

    public init(output: AudioOutput = AVAudioEngineOutput()) {
        self.output = output
    }

    deinit {
        stopDecodeLoop()
        output.stop()
        decoder.close()
    }

    // MARK: - Setup

    public func open(url: URL) throws {
        close()

        do {
            try decoder.open(url: url)
        } catch {
            throw PlaybackError.openFailed(url.path)
        }

        duration = decoder.duration
        sampleRate = decoder.sampleRate
        channels = decoder.channels

        // Reconfigure decoder to output float32 planar at the source's native rate/channels
        let outputFormat = AudioOutputFormat(
            sampleRate: Double(sampleRate),
            channelCount: channels,
            sampleFormat: .float32,
            isInterleaved: false
        )
        do {
            try decoder.reconfigure(outputFormat: outputFormat)
        } catch {
            throw PlaybackError.decodeFailed("Failed to configure decoder output: \(error)")
        }

        let reader = MetadataReader()
        metadata = (try? reader.read(url: url)) ?? AudioMetadata()

        do {
            try output.configure(sampleRate: Double(sampleRate), channels: channels)
        } catch {
            throw PlaybackError.audioOutputFailed(error.localizedDescription)
        }

        state = .idle
    }

    public func close() {
        stopDecodeLoop()
        output.stop()
        decoder.close()

        state = .idle
        _currentTime = 0
        seekBase = 0
        duration = 0
        sampleRate = 0
        channels = 0
        metadata = AudioMetadata()
    }

    // MARK: - Playback control

    public func play() {
        guard sampleRate > 0 else {
            onError?(.notOpen)
            return
        }

        switch state {
        case .idle, .stopped:
            seekBase = 0
            try? output.start()
            state = .playing
            startDecodeLoop()

        case .paused:
            try? output.start()
            state = .playing
            startDecodeLoop()

        case .completed:
            decoder.seek(to: 0)
            _currentTime = 0
            seekBase = 0
            output.stop()
            do {
                try output.configure(sampleRate: Double(sampleRate), channels: channels)
                try output.start()
            } catch {
                onError?(.audioOutputFailed(error.localizedDescription))
                return
            }
            state = .playing
            startDecodeLoop()

        case .playing:
            break
        }
    }

    public func pause() {
        guard state == .playing else { return }
        // Capture position before pausing
        _currentTime = computePlaybackPosition()
        stopDecodeLoop()
        output.pause()
        state = .paused
    }

    public func stop() {
        stopDecodeLoop()
        output.stop()
        decoder.seek(to: 0)
        _currentTime = 0
        seekBase = 0
        state = .stopped
    }

    public func seek(to time: TimeInterval) {
        guard sampleRate > 0 else { return }

        if time >= duration {
            stopDecodeLoop()
            output.stop()
            _currentTime = duration
            state = .completed
            return
        }

        let wasPlaying = state == .playing
        if wasPlaying {
            stopDecodeLoop()
        }

        output.stop()
        decoder.seek(to: time)
        seekBase = time
        _currentTime = time
        onProgress?(time)

        if wasPlaying {
            do {
                try output.configure(sampleRate: Double(sampleRate), channels: channels)
                try output.start()
            } catch {
                onError?(.audioOutputFailed(error.localizedDescription))
                return
            }
            state = .playing
            startDecodeLoop()
        }
    }

    // MARK: - Position tracking

    private func computePlaybackPosition() -> TimeInterval {
        let outputPosition = output.playbackPosition
        guard outputPosition >= 0 else {
            return _currentTime
        }
        let position = seekBase + outputPosition
        return min(position, duration)
    }

    // MARK: - Decode loop

    private func startDecodeLoop() {
        lock.lock()
        guard !isDecoding else {
            lock.unlock()
            return
        }
        isDecoding = true
        stopRequested = false
        lock.unlock()

        queue.async { [weak self] in
            self?.decodeLoop()
        }
    }

    private func stopDecodeLoop() {
        lock.lock()
        stopRequested = true
        lock.unlock()

        // Spin briefly to let the decode loop exit
        for _ in 0..<200 {
            lock.lock()
            let done = !isDecoding
            lock.unlock()
            if done { break }
            usleep(5000) // 5ms
        }
    }

    private func decodeLoop() {
        while true {
            lock.lock()
            if stopRequested {
                isDecoding = false
                lock.unlock()
                return
            }
            lock.unlock()

            do {
                try decoder.decodeNextFrame { frame in
                    output.scheduleAudio(frame)
                }

                // Fire progress with current position
                let position = computePlaybackPosition()
                onProgress?(position)

            } catch let error as DecoderError where isEndOfFile(error) {
                // All data decoded. Wait for audio output to finish.
                let completed = output.waitForCompletion { [weak self] in
                    guard let self else { return true }
                    self.lock.lock()
                    let shouldStop = self.stopRequested
                    self.lock.unlock()
                    return shouldStop
                }

                lock.lock()
                let wasStopRequested = stopRequested
                isDecoding = false
                lock.unlock()

                // Only transition to completed if we weren't interrupted
                if !wasStopRequested && completed {
                    _currentTime = duration
                    state = .completed
                }
                return

            } catch {
                lock.lock()
                isDecoding = false
                lock.unlock()

                onError?(PlaybackError.decodeFailed(error.localizedDescription))
                return
            }
        }
    }

    private func isEndOfFile(_ error: DecoderError) -> Bool {
        if case .endOfFile = error { return true }
        return false
    }
}
