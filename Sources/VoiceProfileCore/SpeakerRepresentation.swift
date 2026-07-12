import Foundation

public struct SpeakerEmbeddingSample: Equatable, Sendable {
    public let embedding: VoiceEmbedding
    public let start: TimeInterval
    public let end: TimeInterval
    public let quality: Double?

    public init(
        embedding: VoiceEmbedding,
        start: TimeInterval,
        end: TimeInterval,
        quality: Double?
    ) {
        self.embedding = embedding
        self.start = start
        self.end = end
        self.quality = quality
    }
}

public struct SpeakerRepresentation: Equatable, Sendable {
    public let speakerID: String
    public let samples: [SpeakerEmbeddingSample]
    public let cleanSpeechSeconds: TimeInterval

    public init(
        speakerID: String,
        samples: [SpeakerEmbeddingSample],
        cleanSpeechSeconds: TimeInterval
    ) {
        self.speakerID = speakerID
        self.samples = samples
        self.cleanSpeechSeconds = cleanSpeechSeconds
    }
}
