import Foundation

public struct EmbeddingModelFingerprint: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let modelID: String
    public let modelRevision: String
    public let preprocessingRevision: String
    public let dimension: Int

    public init(
        provider: String,
        modelID: String,
        modelRevision: String,
        preprocessingRevision: String,
        dimension: Int
    ) {
        self.provider = provider
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.preprocessingRevision = preprocessingRevision
        self.dimension = dimension
    }
}
