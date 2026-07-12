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

struct CalibrationReportWriterHooks: Sendable {
    let beforeWrite: @Sendable (String) throws -> Void
    let record: @Sendable (String) -> Void

    init(
        beforeWrite: @escaping @Sendable (String) throws -> Void = { _ in },
        record: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.beforeWrite = beforeWrite
        self.record = record
    }
}

public enum CalibrationReportWriter {
    public static func write(_ report: CalibrationReport, to directory: URL) throws {
        try write(report, to: directory, hooks: .init())
    }

    static func write(
        _ report: CalibrationReport,
        to directory: URL,
        hooks: CalibrationReportWriterHooks
    ) throws {
        guard directory.path.hasPrefix("/") else {
            throw CalibrationReportWriteError.unsafeOutput
        }
        let name = directory.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw CalibrationReportWriteError.unsafeOutput
        }
        let parentDescriptor = try openDirectoryWithoutFollowingLinks(
            directory.deletingLastPathComponent()
        )
        defer { close(parentDescriptor) }
        var existing = stat()
        if fstatat(parentDescriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            if existing.st_mode & S_IFMT == S_IFLNK { throw CalibrationReportWriteError.unsafeOutput }
            throw CalibrationReportWriteError.outputExists
        }
        let stagingName = ".voice-calibration-\(UUID().uuidString)"
        guard mkdirat(parentDescriptor, stagingName, 0o700) == 0 else {
            throw CalibrationReportWriteError.writeFailed
        }
        let stagingDescriptor = openat(
            parentDescriptor, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard stagingDescriptor >= 0 else {
            _ = unlinkat(parentDescriptor, stagingName, AT_REMOVEDIR)
            throw CalibrationReportWriteError.unsafeOutput
        }
        var published = false
        defer {
            if !published {
                _ = unlinkat(stagingDescriptor, "calibration-report.json", 0)
                _ = unlinkat(stagingDescriptor, "calibration-report.md", 0)
            }
            close(stagingDescriptor)
            if !published { _ = unlinkat(parentDescriptor, stagingName, AT_REMOVEDIR) }
        }
        do {
            try hooks.beforeWrite("calibration-report.json")
            try write(
                try report.jsonData(), named: "calibration-report.json",
                eventName: "json", in: stagingDescriptor, hooks: hooks
            )
            try hooks.beforeWrite("calibration-report.md")
            try write(
                Data(report.markdown().utf8), named: "calibration-report.md",
                eventName: "markdown", in: stagingDescriptor, hooks: hooks
            )
            guard fsync(stagingDescriptor) == 0 else {
                throw CalibrationReportWriteError.writeFailed
            }
            hooks.record("fsync:staging")
            guard renameatx_np(
                parentDescriptor, stagingName, parentDescriptor, name,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                if errno == EEXIST { throw CalibrationReportWriteError.outputExists }
                throw CalibrationReportWriteError.writeFailed
            }
            published = true
            hooks.record("publish")
            guard fsync(parentDescriptor) == 0 else {
                throw CalibrationReportWriteError.writeFailed
            }
            hooks.record("fsync:parent")
        } catch {
            throw error
        }
    }

    private static func openDirectoryWithoutFollowingLinks(_ directory: URL) throws -> Int32 {
        let path: String
        if directory.path == "/var" || directory.path.hasPrefix("/var/") {
            path = "/private" + directory.path
        } else if directory.path == "/tmp" || directory.path.hasPrefix("/tmp/") {
            path = "/private" + directory.path
        } else {
            path = directory.path
        }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw CalibrationReportWriteError.unsafeOutput }
        var current = root
        for component in URL(fileURLWithPath: path, isDirectory: true).pathComponents.dropFirst() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if current != root { close(current) }
            guard next >= 0 else {
                close(root)
                throw CalibrationReportWriteError.unsafeOutput
            }
            current = next
        }
        if current != root { close(root) }
        return current
    }

    private static func write(
        _ data: Data,
        named name: String,
        eventName: String,
        in directory: Int32,
        hooks: CalibrationReportWriterHooks
    ) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CalibrationReportWriteError.writeFailed }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw CalibrationReportWriteError.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CalibrationReportWriteError.writeFailed
        }
        hooks.record("fsync:file:\(eventName)")
    }
}
