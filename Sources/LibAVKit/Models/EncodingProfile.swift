import Foundation

/// A saved encoding profile that stores format-specific settings for reuse.
public struct EncodingProfile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var outputFormat: OutputFormat
    public var encodingSettings: EncodingSettings
    public var outputPathTemplate: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        outputFormat: OutputFormat,
        encodingSettings: EncodingSettings,
        outputPathTemplate: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.outputFormat = outputFormat
        self.encodingSettings = encodingSettings
        self.outputPathTemplate = outputPathTemplate
        self.createdAt = createdAt
    }
}
