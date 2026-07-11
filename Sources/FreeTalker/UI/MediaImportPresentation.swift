import Foundation

struct MediaImportDetail: Sendable, Equatable {
    let job: TranscriptionJob
    let transcript: [TranscriptSegment]
    let turns: [SpeakerTurn]
    let names: [String: String]
    let completedStages: Set<MediaPipelineStage>

    var transcriptReady: Bool { completedStages.contains(.transcribe) }
    var attributedTranscript: [AttributedTranscriptSegment] {
        TimelineJoiner().join(transcript: transcript, speakers: turns)
    }
    var speakerIDs: [String] {
        turns.map(\.speakerID).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    var exportNames: [String: String] {
        MediaImportPresentation.exportNames(speakerIDs: speakerIDs, names: names)
    }
}

enum MediaImportAction: Sendable, Equatable {
    case cancel
    case retry
    case retrySpeakerSeparation
    case export
    case delete
}

struct MediaImportProgress: Sendable, Equatable {
    let label: String
    let fraction: Double
}

enum MediaImportRetention: Int, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case never = -1

    static let `default`: Self = .sevenDays
    var days: Int? { self == .never ? nil : rawValue }

    func purgeCandidates(_ jobs: [TranscriptionJob], now: Date) -> [TranscriptionJob] {
        guard let days else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return jobs.filter { job in
            guard job.kind == .mediaImport, job.state == .ready else { return false }
            return (job.completedAt ?? job.updatedAt) <= cutoff
        }
    }
}

enum MediaImportPresentation {
    static let localOnlyMessage = "Private by design: your media, transcript, and speaker data stays on this Mac."
    static let videoExtractionMessage = "For video, FreeTalker extracts only the audio and does not retain a duplicate video."

    static func acceptsDrop(_ url: URL) -> Bool { MediaImportService.isSupported(url) }

    static func progress(stage: JobStage, overall: Double) -> MediaImportProgress {
        let label = switch stage {
        case .decoding: "Extracting audio"
        case .transcribing: "Transcribing locally"
        case .diarizing: "Downloading speaker model or separating speakers"
        case .finalizing: "Finishing import"
        default: "Preparing import"
        }
        return .init(label: label, fraction: min(1, max(0, overall.isFinite ? overall : 0)))
    }

    static func actions(state: JobState, transcriptReady: Bool) -> [MediaImportAction] {
        switch state {
        case .queued:
            return transcriptReady ? [.cancel, .export] : [.cancel]
        case .processing(let stage):
            if stage == .finalizing { return transcriptReady ? [.export] : [] }
            return transcriptReady ? [.cancel, .export] : [.cancel]
        case .failed(let failure):
            let retry: MediaImportAction = failure.stage == .diarizing && transcriptReady ? .retrySpeakerSeparation : .retry
            return transcriptReady ? [retry, .export, .delete] : [retry, .delete]
        case .cancelled:
            return transcriptReady ? [.retry, .export, .delete] : [.retry, .delete]
        case .ready:
            return transcriptReady ? [.export, .delete] : [.delete]
        }
    }

    static func cancellationMessage(_ outcome: LocalJobRunner.CancellationOutcome) -> String {
        switch outcome {
        case .accepted: "Cancellation requested."
        case .tooLate: "This import is already finishing and can no longer be cancelled."
        case .notRunning: "This import is not currently running."
        }
    }

    static func canExport(transcriptReady: Bool) -> Bool { transcriptReady }

    static func displayName(speakerID: String, names: [String: String], ordinal: Int) -> String {
        let name = names[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Speaker \(ordinal)" : name
    }

    static func exportNames(speakerIDs: [String], names: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: speakerIDs.enumerated().map { index, id in
            (id, displayName(speakerID: id, names: names, ordinal: index + 1))
        })
    }
}
