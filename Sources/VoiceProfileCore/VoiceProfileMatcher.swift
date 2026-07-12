import Foundation

public struct EnrollmentPrototype: Equatable, Sendable {
    public let participantID: String
    public let embedding: VoiceEmbedding
    public let fingerprint: EmbeddingModelFingerprint

    public init(
        participantID: String,
        embedding: VoiceEmbedding,
        fingerprint: EmbeddingModelFingerprint
    ) {
        self.participantID = participantID
        self.embedding = embedding
        self.fingerprint = fingerprint
    }
}

public struct SpeakerMatchCandidate: Equatable, Sendable {
    public let speakerID: String
    public let participantID: String
    public let distance: Double
    public let runnerUpMargin: Double

    public init(
        speakerID: String,
        participantID: String,
        distance: Double,
        runnerUpMargin: Double
    ) {
        self.speakerID = speakerID
        self.participantID = participantID
        self.distance = distance
        self.runnerUpMargin = runnerUpMargin
    }
}

public enum MatchingParametersError: Error, Equatable, Sendable {
    case invalidMaximumDistance
    case invalidMinimumRunnerUpMargin
    case invalidMinimumCleanSpeechSeconds
}

public enum VoiceProfileMatcherError: Error, Equatable, Sendable {
    case emptySpeakerID
    case duplicateSpeakerID(String)
    case emptyParticipantID
}

public struct MatchingParameters: Codable, Equatable, Sendable {
    public let maximumDistance: Double
    public let minimumRunnerUpMargin: Double
    public let minimumCleanSpeechSeconds: Double

    public init(
        maximumDistance: Double,
        minimumRunnerUpMargin: Double,
        minimumCleanSpeechSeconds: Double
    ) throws {
        guard maximumDistance.isFinite, maximumDistance >= 0, maximumDistance <= 2 else {
            throw MatchingParametersError.invalidMaximumDistance
        }
        guard minimumRunnerUpMargin.isFinite,
              minimumRunnerUpMargin >= 0,
              minimumRunnerUpMargin <= 2 else {
            throw MatchingParametersError.invalidMinimumRunnerUpMargin
        }
        guard minimumCleanSpeechSeconds.isFinite, minimumCleanSpeechSeconds >= 0 else {
            throw MatchingParametersError.invalidMinimumCleanSpeechSeconds
        }
        self.maximumDistance = maximumDistance
        self.minimumRunnerUpMargin = minimumRunnerUpMargin
        self.minimumCleanSpeechSeconds = minimumCleanSpeechSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumDistance: values.decode(Double.self, forKey: .maximumDistance),
            minimumRunnerUpMargin: values.decode(Double.self, forKey: .minimumRunnerUpMargin),
            minimumCleanSpeechSeconds: values.decode(Double.self, forKey: .minimumCleanSpeechSeconds)
        )
    }
}

public struct VoiceProfileMatcher: Sendable {
    private let parameters: MatchingParameters

    public init(parameters: MatchingParameters) {
        self.parameters = parameters
    }

    public func candidates(
        speakers: [SpeakerRepresentation],
        speakerFingerprint: EmbeddingModelFingerprint,
        prototypes: [EnrollmentPrototype]
    ) throws -> [SpeakerMatchCandidate] {
        if speakers.contains(where: { $0.speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw VoiceProfileMatcherError.emptySpeakerID
        }
        let speakerCounts = Dictionary(grouping: speakers, by: \.speakerID).mapValues(\.count)
        if let duplicate = speakerCounts.filter({ $0.value > 1 }).keys.sorted().first {
            throw VoiceProfileMatcherError.duplicateSpeakerID(duplicate)
        }
        let speakers = speakers.sorted { $0.speakerID < $1.speakerID }

        let compatible = prototypes.filter { $0.fingerprint == speakerFingerprint }
        if compatible.contains(where: {
            $0.participantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            throw VoiceProfileMatcherError.emptyParticipantID
        }
        guard !speakers.isEmpty else { return [] }
        let grouped = Dictionary(grouping: compatible, by: \.participantID)
        let participantIDs = grouped.keys.sorted()
        guard !participantIDs.isEmpty else { return [] }

        let distances = try speakers.map { speaker in
            try participantIDs.map { participantID in
                try ParticipantPrototypeScorer.score(
                    speaker: speaker,
                    prototypes: grouped[participantID, default: []]
                )
            }
        }
        let margins = distances.map { row in
            row.enumerated().map { index, distance in
                let runnerUp = row.enumerated()
                    .filter { $0.offset != index }
                    .map(\.element)
                    .min() ?? 2
                return runnerUp - distance
            }
        }

        let rejectedCost = 1_000_000.0
        let unknownCost = parameters.maximumDistance + 1
        let costs = speakers.indices.map { speakerIndex in
            let speaker = speakers[speakerIndex]
            let real = participantIDs.indices.map { participantIndex in
                let distance = distances[speakerIndex][participantIndex]
                let eligible = speaker.cleanSpeechSeconds.isFinite
                    && speaker.cleanSpeechSeconds >= parameters.minimumCleanSpeechSeconds
                    && distance.isFinite
                    && distance <= parameters.maximumDistance
                    && (parameters.minimumRunnerUpMargin == 0
                        || margins[speakerIndex][participantIndex] >= parameters.minimumRunnerUpMargin)
                return eligible ? distance : rejectedCost
            }
            return real + Array(repeating: unknownCost, count: speakers.count)
        }

        let assignment = minimumCostAssignment(costs)
        return speakers.indices.compactMap { speakerIndex in
            let participantIndex = assignment[speakerIndex]
            guard participantIndex < participantIDs.count,
                  costs[speakerIndex][participantIndex] < rejectedCost else { return nil }
            return SpeakerMatchCandidate(
                speakerID: speakers[speakerIndex].speakerID,
                participantID: participantIDs[participantIndex],
                distance: distances[speakerIndex][participantIndex],
                runnerUpMargin: margins[speakerIndex][participantIndex]
            )
        }
    }

    // Hungarian algorithm for rows <= columns, O(rows² * columns).
    private func minimumCostAssignment(_ costs: [[Double]]) -> [Int] {
        let rowCount = costs.count
        let columnCount = costs[0].count
        var rowPotential = Array(repeating: 0.0, count: rowCount + 1)
        var columnPotential = Array(repeating: 0.0, count: columnCount + 1)
        var matchedRow = Array(repeating: 0, count: columnCount + 1)
        var predecessor = Array(repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            matchedRow[0] = row
            var column = 0
            var minimum = Array(repeating: Double.infinity, count: columnCount + 1)
            var used = Array(repeating: false, count: columnCount + 1)
            repeat {
                used[column] = true
                let currentRow = matchedRow[column]
                var delta = Double.infinity
                var nextColumn = 0
                for candidate in 1...columnCount where !used[candidate] {
                    let reduced = costs[currentRow - 1][candidate - 1]
                        - rowPotential[currentRow] - columnPotential[candidate]
                    if reduced < minimum[candidate] {
                        minimum[candidate] = reduced
                        predecessor[candidate] = column
                    }
                    if minimum[candidate] < delta {
                        delta = minimum[candidate]
                        nextColumn = candidate
                    }
                }
                for candidate in 0...columnCount {
                    if used[candidate] {
                        rowPotential[matchedRow[candidate]] += delta
                        columnPotential[candidate] -= delta
                    } else {
                        minimum[candidate] -= delta
                    }
                }
                column = nextColumn
            } while matchedRow[column] != 0

            repeat {
                let previous = predecessor[column]
                matchedRow[column] = matchedRow[previous]
                column = previous
            } while column != 0
        }

        var assignment = Array(repeating: 0, count: rowCount)
        for column in 1...columnCount where matchedRow[column] != 0 {
            assignment[matchedRow[column] - 1] = column - 1
        }
        return assignment
    }
}
