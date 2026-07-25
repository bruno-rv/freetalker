import AVFoundation
import Foundation

/// The real work behind `FreeTalker.sdef`'s two commands (BRAINSTORM_AUTOMATION_SURFACE.md).
/// Kept separate from the `NSScriptCommand` subclasses so it's callable (and its errors
/// inspectable) without any Apple Event/Cocoa Scripting machinery, and so the command classes
/// stay thin adapters over it.
///
/// `transcribe` calls the exact pipeline the UI uses — `MediaImportService`/`LocalJobRunner` via
/// `JobLibraryStore` — never a parallel implementation. `cleanUpText` calls the same
/// `PostProcessor.process(_:)` contract the UI uses, but ALWAYS through `AppleFMProcessor` (Apple's
/// on-device Foundation Models), never `AppCoordinator.resolveActiveProcessor()`'s cloud/on-device
/// selection — see the doc comment on `cleanUpText` for why.
@MainActor
enum AutomationService {
    /// How often `transcribe` re-checks the job's state while waiting for it to finish. Short
    /// enough that a caller blocked on the AppleEvent reply doesn't perceive extra latency beyond
    /// the transcription itself; long enough not to spin the main actor.
    private static let pollInterval: Duration = .milliseconds(200)

    // ponytail: fixed 2-hour app-side deadline for `transcribe` (Codex round-1 Finding 7).
    // AppleScript's default sender timeout is ~2 minutes and ScriptingBridge's is ~1, but neither
    // cancels FreeTalker's own work — Cocoa gives no sender-death callback, so the bound has to be
    // app-side. Two hours is generous for any legitimate recording at WhisperKit's typical
    // faster-than-real-time throughput; a caller transcribing long media should set an explicit
    // `with timeout of 7200` (AppleScript) / `SBApplication.timeout` (ScriptingBridge) — see
    // `FreeTalker.sdef`'s `transcribe` command comment. Upgrade path: derive this from the
    // probed media duration instead of one fixed ceiling for every call.
    private static let automationDeadline: Duration = .seconds(7_200)

    /// Tracks the in-flight import job across the deadline race below so a timeout can cancel it
    /// instead of leaving it running forever. An `actor` (not a plain `@MainActor` class) so it's
    /// unconditionally `Sendable` across the task-group's child tasks without fighting Swift 6's
    /// region-based isolation checker over a value used both inside a child task and after it.
    private actor JobHandle {
        private(set) var jobID: UUID?
        func record(_ id: UUID) { jobID = id }
    }

    static func transcribe(
        fileURL: URL,
        format: TranscriptFormat,
        includeSpeakerLabels: Bool
    ) async throws -> String {
        try AutomationGate.checkEnabled(AppSettings.shared.automationEnabled)

        // Codex round-1 Finding 2 / round-2 Finding 1: the automation toggle alone grants no
        // per-file authority — only a file inside the user's chosen Automation folder may be
        // read, and that folder's identity comes from a bookmark bound to the real directory,
        // never the mutable `automationFolderPath` string. Every check downstream uses the
        // CANONICAL (symlink-resolved) URL this returns, never the caller-supplied one.
        let authorized = try AutomationFileAuthorization.authorize(
            fileURL, automationFolderBookmark: AppSettings.shared.automationFolderBookmark
        )
        guard MediaImportService.isSupported(authorized.url) else { throw AutomationError.unsupportedFileType }

        // Codex round-2 Finding 2: no `await` occurs between `authorize` above and `stage` here —
        // `stage` pins the real file via an `O_NOFOLLOW` file descriptor and copies its verified
        // bytes into app-owned staging BEFORE any AVFoundation or import call ever runs, so the
        // async duration probe and `importMedia` below can never reopen a caller-swapped path.
        let staged = try AutomationMediaStaging.stage(
            canonicalFolder: authorized.folder,
            canonicalFile: authorized.url,
            maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
        )
        defer { staged.cleanup() }
        // Captured by the task group's child task below instead of `staged` itself: `URL` is
        // `Sendable`, so this avoids requiring `AutomationMediaStaging.StagedFile` (whose cleanup
        // closure isn't) to cross the child task's concurrency domain.
        let stagedURL = staged.url

        await AppCoordinator.shared.launchMediaImportWorkflows()
        guard let jobLibraryStore = AppCoordinator.shared.jobLibraryStore else {
            throw AutomationErrorSanitizer.processingFailure(
                message: "import queue not ready", context: "transcribe"
            )
        }

        let handle = JobHandle()
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await performTranscription(
                        stagedURL: stagedURL,
                        format: format,
                        includeSpeakerLabels: includeSpeakerLabels,
                        store: jobLibraryStore,
                        handle: handle
                    )
                }
                group.addTask {
                    try await Task.sleep(for: automationDeadline)
                    throw AutomationError.timedOut
                }
                guard let result = try await group.next() else { throw AutomationError.timedOut }
                group.cancelAll()
                return result
            }
        } catch AutomationError.timedOut {
            if let jobID = await handle.jobID {
                _ = try? await jobLibraryStore.cancelImport(id: jobID)
            }
            throw AutomationError.timedOut
        }
    }

    private static func performTranscription(
        stagedURL: URL,
        format: TranscriptFormat,
        includeSpeakerLabels: Bool,
        store: JobLibraryStore,
        handle: JobHandle
    ) async throws -> String {
        // Codex round-1 Finding 4 / round-2 Finding 5: a small, compressed file can still decode
        // to a multi-hour asset, and a thrown load or an indefinite/NaN/infinite duration must be
        // REJECTED, never silently skipped — a failed or non-finite probe is not evidence the file
        // is short. This runs against the STAGING copy (round-2 Finding 2), never the
        // caller-supplied path.
        let asset = AVURLAsset(url: stagedURL)
        try await AutomationMediaGuard.validateDuration { try await asset.load(.duration) }

        let jobID: UUID
        do {
            jobID = try await store.importMedia(stagedURL)
        } catch let error as MediaImportError {
            if error == .unsupportedType { throw AutomationError.unsupportedFileType }
            throw AutomationErrorSanitizer.processingFailure(error, context: "transcribe (import)")
        }
        await handle.record(jobID)

        let detail = try await waitForCompletion(jobID: jobID, store: store)
        return TranscriptExporter().export(
            detail.attributedTranscript,
            format: format,
            speakerNames: detail.exportNames,
            includeSpeakerLabels: includeSpeakerLabels
        )
    }

    /// Always routes through `AppleFMProcessor` — Apple's on-device Foundation Models — never
    /// `AppCoordinator.resolveActiveProcessor()`'s cloud/on-device selection.
    ///
    /// Codex round-1 Finding 1 (CRITICAL, confused-deputy API-key exfiltration): a same-user
    /// process could otherwise flip `automationEnabled` on via `defaults`, repoint the
    /// provider/base-URL/model preferences at an attacker endpoint, and have `clean up` read the
    /// protected Keychain key and send it there. Routing `clean up` at the on-device processor
    /// UNCONDITIONALLY — regardless of what the user has configured for interactive dictation —
    /// removes the vector entirely: no provider key is ever read, no endpoint is ever contacted,
    /// no cloud tokens are ever spent, by automation.
    ///
    /// Consequence, stated honestly: cloud-only capabilities have no automation path. Today that's
    /// output-language translation (`AppleFMProcessor` throws `FMError.translationUnsupported` for
    /// any `languagePolicy` other than `.preserveSource`, which is unreachable from `clean up`
    /// today — this sdef exposes no language parameter). If cloud-only capabilities are ever added
    /// to the sdef, they surface `AutomationError.cloudCapabilityUnavailable` here — a clear,
    /// distinct error, never a silent fallback to a different result.
    static func cleanUpText(_ text: String, templateName: String) async throws -> String {
        try AutomationGate.checkEnabled(AppSettings.shared.automationEnabled)
        guard let template = TemplateStore.resolveTemplate(named: templateName, in: TemplateStore.shared.templates) else {
            throw AutomationError.unknownTemplate(templateName)
        }

        let request = PostProcessingRequest(
            transcript: text,
            template: template,
            appName: nil,
            languagePolicy: .preserveSource,
            // No spoken audio exists in this path, so voice commands can never apply — same
            // reasoning as translation/Scratchpad transformations (PLAN.md PR A, item 2).
            voiceCommandPolicy: .disabled,
            // Codex round-1 Finding 5: `clean up` puts attacker-supplied `text` in the same
            // user-role prompt as everything else. Never thread the user's real vocabulary in —
            // externally supplied text has no legitimate reason to see it, and this closes the
            // "ask the model to echo the vocabulary back" leak.
            vocabulary: []
        )
        do {
            return try await AppleFMProcessor().process(request)
        } catch {
            throw AutomationErrorSanitizer.processorFailure(error)
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
                throw AutomationErrorSanitizer.processingFailure(
                    message: failure.message, context: "transcribe"
                )
            case .cancelled:
                throw AutomationError.cancelled
            case .queued, .processing:
                try await Task.sleep(for: pollInterval)
            }
        }
    }
}
