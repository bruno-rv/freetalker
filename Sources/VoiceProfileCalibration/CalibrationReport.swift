import Darwin
import Foundation
import VoiceProfileCore

public struct CalibrationDistribution: Codable, Equatable, Sendable {
    public let count: Int
    public let quantiles: [String: Double]

    public init(_ values: [Double]) {
        let sorted = values.filter(\ .isFinite).sorted()
        count = sorted.count
        quantiles = sorted.isEmpty ? [:] : [
            "p05": Self.quantile(sorted, 0.05), "p25": Self.quantile(sorted, 0.25),
            "p50": Self.quantile(sorted, 0.5), "p75": Self.quantile(sorted, 0.75),
            "p95": Self.quantile(sorted, 0.95)
        ]
    }

    private static func quantile(_ values: [Double], _ percentile: Double) -> Double {
        let position = percentile * Double(values.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return values[lower] }
        return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
    }
}

public struct CalibrationCohort: Codable, Equatable, Sendable {
    public let participantCount: Int
    public let sessionCount: Int
    public let acceptedSampleCount: Int
    public let rejectedSampleCount: Int
}

public struct CalibrationReport: Codable, Equatable, Sendable {
    public let fingerprint: EmbeddingModelFingerprint
    public let cohort: CalibrationCohort
    public let samePerson: CalibrationDistribution
    public let differentPerson: CalibrationDistribution
    public let durationBins: [CalibrationBin]
    public let qualityBins: [CalibrationBin]
    public let thresholdMetrics: [ThresholdMetrics]
    public let runnerUpMargins: CalibrationDistribution
    public let warnings: [String]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    public func markdown() -> String {
        func distribution(_ value: CalibrationDistribution) -> String {
            let values = value.quantiles.keys.sorted().map { "\($0)=\(value.quantiles[$0]!)" }.joined(separator: ", ")
            return "count=\(value.count)\(values.isEmpty ? "" : ", \(values)")"
        }
        let thresholdRows = thresholdMetrics.map {
            "| \($0.threshold) | \($0.falseMatchCount) | \($0.missedMatchCount) | \($0.trueMatchCount) | \($0.trueRejectCount) |"
        }.joined(separator: "\n")
        let warningRows = warnings.isEmpty ? "- none" : warnings.map { "- \($0)" }.joined(separator: "\n")
        return """
        # Voice Profile Calibration Report

        Model fingerprint: \(fingerprint.provider) / \(fingerprint.modelID) / \(fingerprint.modelRevision) / \(fingerprint.preprocessingRevision) / \(fingerprint.dimension)

        Cohort: participants=\(cohort.participantCount), sessions=\(cohort.sessionCount), acceptedSamples=\(cohort.acceptedSampleCount), rejectedSamples=\(cohort.rejectedSampleCount)

        samePerson: \(distribution(samePerson))

        differentPerson: \(distribution(differentPerson))

        durationBins: \(durationBins)

        qualityBins: \(qualityBins)

        runnerUpMargins: \(distribution(runnerUpMargins))

        thresholdMetrics:

        | threshold | false matches | missed matches | true matches | true rejects |
        | --- | --- | --- | --- | --- |
        \(thresholdRows)

        Warnings:
        \(warningRows)
        """ + "\n"
    }

}

public enum CalibrationReportWriteError: Error, Equatable, Sendable, CustomStringConvertible {
    case outputExists, unsafeOutput, writeFailed
    public var description: String {
        switch self {
        case .outputExists: "output directory already exists"
        case .unsafeOutput: "unsafe output destination"
        case .writeFailed: "failed to write calibration report"
        }
    }
}

public enum CalibrationReportWriter {
    public static func write(_ report: CalibrationReport, to directory: URL) throws {
        guard directory.path.hasPrefix("/") else {
            throw CalibrationReportWriteError.unsafeOutput
        }
        guard let resolvedParent = realpath(directory.deletingLastPathComponent().path, nil) else {
            throw CalibrationReportWriteError.unsafeOutput
        }
        defer { free(resolvedParent) }
        let parent = URL(fileURLWithFileSystemRepresentation: resolvedParent, isDirectory: true, relativeTo: nil)
        guard try ancestorsAreSafe(parent) else { throw CalibrationReportWriteError.unsafeOutput }
        let name = directory.lastPathComponent
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { throw CalibrationReportWriteError.unsafeOutput }
        defer { close(parentDescriptor) }
        var existing = stat()
        if fstatat(parentDescriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            if existing.st_mode & S_IFMT == S_IFLNK { throw CalibrationReportWriteError.unsafeOutput }
            throw CalibrationReportWriteError.outputExists
        }
        guard mkdirat(parentDescriptor, name, 0o700) == 0 else {
            if errno == EEXIST { throw CalibrationReportWriteError.outputExists }
            throw CalibrationReportWriteError.writeFailed
        }
        let descriptor = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
            throw CalibrationReportWriteError.unsafeOutput
        }
        defer { close(descriptor) }
        do {
            try write(try report.jsonData(), named: "calibration-report.json", in: descriptor)
            try write(Data(report.markdown().utf8), named: "calibration-report.md", in: descriptor)
        } catch {
            unlinkat(descriptor, "calibration-report.json", 0)
            unlinkat(descriptor, "calibration-report.md", 0)
            _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
            throw error
        }
    }

    private static func ancestorsAreSafe(_ directory: URL) throws -> Bool {
        var current = directory
        while current.path != "/" {
            var metadata = stat()
            if lstat(current.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
            } else if errno != ENOENT { return false }
            current.deleteLastPathComponent()
        }
        return true
    }

    private static func write(_ data: Data, named name: String, in directory: Int32) throws {
        let temporary = ".\(name).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CalibrationReportWriteError.writeFailed }
        var success = false
        defer {
            close(descriptor)
            if !success { unlinkat(directory, temporary, 0) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw CalibrationReportWriteError.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              renameat(directory, temporary, directory, name) == 0 else {
            throw CalibrationReportWriteError.writeFailed
        }
        success = true
    }
}
