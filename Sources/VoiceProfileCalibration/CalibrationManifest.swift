import Foundation

public struct CalibrationManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let samples: [CalibrationSample]

    public init(version: Int, samples: [CalibrationSample]) {
        self.version = version
        self.samples = samples
    }

    public func validatedSamples() throws -> [CalibrationSample] {
        guard version == 1 else { throw CalibrationManifestError.unsupportedVersion(version) }
        var sampleIDs = Set<String>()
        for sample in samples {
            try sample.validate()
            guard sampleIDs.insert(sample.sampleID).inserted else {
                throw CalibrationManifestError.duplicateSampleID(sample.sampleID)
            }
        }
        let participants = Dictionary(grouping: samples, by: \ .participantID)
        guard participants.count >= 2 else { throw CalibrationManifestError.insufficientParticipants }
        for participantID in participants.keys.sorted() {
            let sessions = Set(participants[participantID, default: []].map(\ .sessionID))
            guard sessions.count >= 2 else {
                throw CalibrationManifestError.insufficientSessions(participantID: participantID)
            }
        }
        return samples.sorted { $0.sampleID < $1.sampleID }
    }
}

public struct CalibrationSample: Codable, Equatable, Sendable {
    public let sampleID: String
    public let participantID: String
    public let sessionID: String
    public let mediaPath: String
    public let microphone: String
    public let environment: String
    public let expectedSpeakerID: String
    public let consentConfirmed: Bool

    public init(
        sampleID: String, participantID: String, sessionID: String, mediaPath: String,
        microphone: String, environment: String, expectedSpeakerID: String,
        consentConfirmed: Bool
    ) {
        self.sampleID = sampleID
        self.participantID = participantID
        self.sessionID = sessionID
        self.mediaPath = mediaPath
        self.microphone = microphone
        self.environment = environment
        self.expectedSpeakerID = expectedSpeakerID
        self.consentConfirmed = consentConfirmed
    }

    fileprivate func validate() throws {
        for (field, value) in [
            ("sampleID", sampleID), ("participantID", participantID),
            ("sessionID", sessionID), ("expectedSpeakerID", expectedSpeakerID)
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CalibrationManifestError.blankIdentifier(field: field, sampleID: safeSampleID)
        }
        guard consentConfirmed else { throw CalibrationManifestError.consentNotConfirmed(sampleID) }
        guard mediaPath.hasPrefix("/") else { throw CalibrationManifestError.invalidMedia(sampleID) }
        var metadata = stat()
        guard lstat(mediaPath, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw CalibrationManifestError.invalidMedia(sampleID)
        }
    }

    private var safeSampleID: String {
        sampleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<blank>" : sampleID
    }
}

public enum CalibrationManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case duplicateSampleID(String)
    case blankIdentifier(field: String, sampleID: String)
    case invalidMedia(String)
    case consentNotConfirmed(String)
    case insufficientParticipants
    case insufficientSessions(participantID: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let value): "unsupported manifest version \(value)"
        case .duplicateSampleID(let id): "duplicate sample ID: \(id)"
        case .blankIdentifier(let field, let id): "blank \(field) for sample ID: \(id)"
        case .invalidMedia(let id): "invalid media for sample ID: \(id)"
        case .consentNotConfirmed(let id): "consent not confirmed for sample ID: \(id)"
        case .insufficientParticipants: "insufficient participant cohort"
        case .insufficientSessions(let id): "insufficient sessions for participant ID: \(id)"
        }
    }
}

public struct CalibrationArguments: Equatable, Sendable {
    public let manifestURL: URL
    public let outputDirectoryURL: URL

    public static func parse(_ arguments: [String]) throws -> Self {
        let allowed = Set(["--manifest", "--output-directory"])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key) else { throw CalibrationArgumentError.unknownArgument(key) }
            guard values[key] == nil else { throw CalibrationArgumentError.duplicateArgument(key) }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CalibrationArgumentError.missingValue(key)
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        for key in ["--manifest", "--output-directory"] where values[key] == nil {
            throw CalibrationArgumentError.missingArgument(key)
        }
        for key in ["--manifest", "--output-directory"] where !values[key]!.hasPrefix("/") {
            throw CalibrationArgumentError.nonAbsoluteArgument(key)
        }
        return Self(
            manifestURL: URL(fileURLWithPath: values["--manifest"]!),
            outputDirectoryURL: URL(fileURLWithPath: values["--output-directory"]!)
        )
    }
}

public enum CalibrationArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingArgument(String), missingValue(String), duplicateArgument(String)
    case unknownArgument(String), nonAbsoluteArgument(String)

    public var description: String {
        switch self {
        case .missingArgument(let key): "missing argument: \(key)"
        case .missingValue(let key): "missing value for argument: \(key)"
        case .duplicateArgument(let key): "duplicate argument: \(key)"
        case .unknownArgument: "unknown argument"
        case .nonAbsoluteArgument(let key): "argument requires an absolute path: \(key)"
        }
    }
}
