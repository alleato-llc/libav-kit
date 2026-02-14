import AVFoundation

/// Default ``AudioOutput`` implementation backed by `AVAudioEngine` and
/// `AVAudioPlayerNode`.
public final class AVAudioEngineOutput: AudioOutput, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var cachedFormat: AVAudioFormat?

    /// Optional callback that receives real-time PCM samples (channel 0, Float32)
    /// from a tap on the main mixer node. Called on the audio render thread.
    public var onSamples: (([Float]) -> Void)?

    public init() {
        engine.attach(playerNode)
    }

    deinit {
        engine.stop()
    }

    // MARK: - AudioOutput

    public func configure(sampleRate: Double, channels: Int) throws {
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        cachedFormat = audioFormat
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let callback = self?.onSamples,
                  let floatData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
            callback(samples)
        }

        do {
            try engine.start()
        } catch {
            throw PlaybackError.audioOutputFailed(error.localizedDescription)
        }
    }

    public func start() throws {
        playerNode.play()
    }

    public func pause() {
        playerNode.pause()
    }

    public func stop() {
        engine.mainMixerNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        playerNode.stop()
        engine.disconnectNodeOutput(playerNode)
        cachedFormat = nil
    }

    public func scheduleAudio(_ frame: DecodedFrame) {
        guard let format = cachedFormat,
              let avBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.frameCount)),
              let floatData = avBuffer.floatChannelData else { return }
        for ch in 0..<frame.channelCount {
            floatData[ch].update(from: frame.channelData[ch], count: frame.frameCount)
        }
        avBuffer.frameLength = AVAudioFrameCount(frame.frameCount)
        playerNode.scheduleBuffer(avBuffer)
    }

    @discardableResult
    public func waitForCompletion(checkCancelled: () -> Bool) -> Bool {
        let format = playerNode.outputFormat(forBus: 0)
        guard let sentinel = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            return false
        }
        sentinel.frameLength = 0

        let semaphore = DispatchSemaphore(value: 0)
        playerNode.scheduleBuffer(sentinel) {
            semaphore.signal()
        }

        while true {
            if semaphore.wait(timeout: .now() + .milliseconds(50)) == .success {
                return true
            }
            if checkCancelled() { return false }
        }
    }

    public var playbackPosition: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0 else {
            return -1
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    public var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = max(0, min(1, newValue)) }
    }
}
