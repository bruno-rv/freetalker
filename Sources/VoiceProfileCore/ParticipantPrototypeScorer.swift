import Foundation

public enum ParticipantPrototypeScorerError: Error, Equatable, Sendable {
    case emptySpeakerSamples
    case emptyPrototypes
    case mixedParticipantIDs
    case mixedFingerprints
}

public enum ParticipantPrototypeScorer {
    public static func score(
        speaker: SpeakerRepresentation,
        prototypes: [EnrollmentPrototype]
    ) throws -> Double {
        guard !speaker.samples.isEmpty else {
            throw ParticipantPrototypeScorerError.emptySpeakerSamples
        }
        guard let first = prototypes.first else {
            throw ParticipantPrototypeScorerError.emptyPrototypes
        }
        guard prototypes.allSatisfy({ $0.participantID == first.participantID }) else {
            throw ParticipantPrototypeScorerError.mixedParticipantIDs
        }
        guard prototypes.allSatisfy({ $0.fingerprint == first.fingerprint }) else {
            throw ParticipantPrototypeScorerError.mixedFingerprints
        }

        return prototypes.map { prototype in
            let distances = speaker.samples.map {
                $0.embedding.cosineDistance(to: prototype.embedding)
            }.sorted()
            return distances.reduce(0, +) / Double(distances.count)
        }.min()!
    }
}
