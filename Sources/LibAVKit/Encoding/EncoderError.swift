import Foundation

public enum EncoderError: Error, LocalizedError {
    case outputFormatNotFound(String)
    case encoderNotFound(String)
    case encoderOpenFailed(String)
    case outputOpenFailed(String)
    case headerWriteFailed
    case encodingFailed(String)
    case resamplerFailed
    case unsupportedSampleRate(requested: Int, supported: [Int], encoder: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .outputFormatNotFound(format):
            "Could not determine output format for .\(format)"
        case let .encoderNotFound(name):
            "Encoder not found: \(name)"
        case let .encoderOpenFailed(detail):
            "Failed to open encoder: \(detail)"
        case let .outputOpenFailed(path):
            "Failed to open output file: \(path)"
        case .headerWriteFailed:
            "Failed to write output file header"
        case let .encodingFailed(detail):
            "Encoding failed: \(detail)"
        case .resamplerFailed:
            "Failed to initialize audio resampler"
        case let .unsupportedSampleRate(requested, supported, encoder):
            "\(encoder) encoder does not support \(requested) Hz; supported rates: \(supported.map(String.init).joined(separator: ", "))"
        case .cancelled:
            "Encoding was cancelled"
        }
    }
}
