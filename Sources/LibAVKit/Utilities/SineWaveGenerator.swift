import Foundation

/// Generates sine wave audio samples for testing purposes.
public enum SineWaveGenerator {
    /// Generate planar float samples for a sine wave.
    ///
    /// - Parameters:
    ///   - frequency: Tone frequency in Hz (e.g. 440.0 for A4)
    ///   - sampleRate: Sample rate in Hz (e.g. 44100)
    ///   - duration: Duration in seconds
    ///   - channels: Number of audio channels (each channel gets identical data)
    /// - Returns: Planar float arrays `[channel][sample]`
    public static func generate(
        frequency: Double, sampleRate: Int, duration: Double, channels: Int
    ) -> [[Float]] {
        let sampleCount = Int(Double(sampleRate) * duration)
        let angularFrequency = 2.0 * Double.pi * frequency / Double(sampleRate)

        let mono = (0..<sampleCount).map { i in
            Float(sin(angularFrequency * Double(i)))
        }

        return (0..<channels).map { _ in mono }
    }
}
