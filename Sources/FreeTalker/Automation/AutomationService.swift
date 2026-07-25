import Foundation

/// The real work behind `FreeTalker.sdef`'s two commands (BRAINSTORM_AUTOMATION_SURFACE.md).
/// Kept separate from the `NSScriptCommand` subclasses so it's callable (and its errors
/// inspectable) without any Apple Event/Cocoa Scripting machinery, and so the command classes
/// stay thin adapters over it.
///
/// Both capabilities call the exact pipelines the UI uses — `MediaImportService`/`LocalJobRunner`
/// via `JobLibraryStore` for `transcribe`, `AppCoordinator.resolveActiveProcessor()` +
/// `PostProcessor.process(_:)` for `cleanUpText` — never a parallel implementation.
@MainActor
enum AutomationService {
    /// How often `transcribe` re-checks the job's state while waiting for it to finish. Short
    /// enough that a caller blocked on the AppleEvent reply doesn't perceive extra latency beyond
    /// the transcription itself; long enough not to spin the main actor.
    private static let pollInterval: Duration = .milliseconds(200)

    static func transcribe(
        fileURL: URL,
        format: TranscriptFormat,
        includeSpeakerLabels: Bool
    ) async throws -> String {
        try AutomationGate.checkEnabled(AppSettings.shared.automationEnabled)
        guard MediaImportService.isSupported(fileURL) else { throw AutomationError.unsupportedFileType }

        // Idempotent — a no-op if the app's normal launch sequence already wired this up, which
        // it always will have by the time a user can reach a running FreeTalker to script it.
        // Guards the (unlikely, but not impossible) case automation runs before that finishes.
        await AppCoordinator.shared.launchMediaImportWorkflows()
        guard let jobLibraryStore = AppCoordinator.shared.jobLibraryStore else {
            throw AutomationError.pipelineFailed("FreeTalker's import queue isn't ready yet. Try again in a moment.")
        }

        let jobID: UUID
        do {
            jobID = try await jobLibraryStore.importMedia(fileURL)
        } catch let error as MediaImportError {
            if error == .unsupportedType { throw AutomationError.unsupportedFileType }
            throw AutomationError.pipelineFailed(error.localizedDescription)
        }

        let detail = try await waitForCompletion(jobID: jobID, store: jobLibraryStore)
        return TranscriptExporter().export(
            detail.attributedTranscript,
            format: format,
            speakerNames: detail.exportNames,
            includeSpeakerLabels: includeSpeakerLabels
        )
    }

    static func cleanUpText(_ text: String, templateName: String) async throws -> String {
        try AutomationGate.checkEnabled(AppSettings.shared.automationEnabled)
        guard let template = TemplateStore.resolveTemplate(named: templateName, in: TemplateStore.shared.templates) else {
            throw AutomationError.unknownTemplate(templateName)
        }

        let snapshot = AppSettings.shared.cloudLLMSnapshot
        let request = PostProcessingRequest(
            transcript: text,
            template: template,
            appName: nil,
            languagePolicy: .preserveSource,
            // No spoken audio exists in this path, so voice commands can never apply — same
            // reasoning as translation/Scratchpad transformations (PLAN.md PR A, item 2).
            voiceCommandPolicy: .disabled,
            vocabulary: snapshot.vocabulary
        )
        do {
            return try await AppCoordinator.shared.resolveActiveProcessor().process(request)
        } catch {
            throw AutomationError.pipelineFailed(error.localizedDescription)
        }
    }

    /// Polls the same `MediaImportDetail` the Imports window's detail view reads, so a job
    /// cancelled from that window while this call is blocked is observed here too — this is what
    /// keeps `transcribe` visible AND cancellable in the Imports window while the caller waits.
    private static func waitForCompletion(
        jobID: UUID,
        store: JobLibraryStore
    ) async throws -> MediaImportDetail {
        while true {
            try Task.checkCancellation()
            let detail = try await store.importDetail(id: jobID)
            switch detail.job.state {
            case .ready:
                return detail
            case .failed(let failure):
                throw AutomationError.pipelineFailed(failure.message)
            case .cancelled:
                throw AutomationError.cancelled
            case .queued, .processing:
                try await Task.sleep(for: pollInterval)
            }
        }
    }
}
