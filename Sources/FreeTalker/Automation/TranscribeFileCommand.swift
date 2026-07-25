import Foundation

/// Cocoa Scripting entry point for `FreeTalker.sdef`'s `transcribe` command
/// (BRAINSTORM_AUTOMATION_SURFACE.md capability 1) — reachable from Shortcuts' Run AppleScript
/// action, `osascript`, Raycast, and Alfred. Runs `AutomationService.transcribe`, which uses the
/// SAME background job queue the Imports window uses, so the job stays visible and cancellable
/// there while this command's caller blocks for the result.
///
/// Suspends the AppleEvent reply (`suspendExecution`/`resumeExecution(withResult:)`) instead of
/// blocking a thread: `AutomationService` needs the main actor (it goes through
/// `AppCoordinator`/`AppSettings`), and Apple Event dispatch itself runs there too, so a thread
/// that actually blocked while resuming that same work would deadlock. The suspend/resume pair is
/// exactly what Cocoa Scripting has offered slow commands since it's an ordinary async reply, not
/// a workaround.
final class TranscribeFileCommand: NSScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        guard let fileURL = Self.resolveFileURL(directParameter) else {
            fail(.invalidInput("Provide a file to transcribe."))
            return nil
        }
        let format = AutomationTranscriptFormat.parse(evaluatedArguments?["format"] as? String)
        let includeSpeakerLabels = (evaluatedArguments?["withSpeakerLabels"] as? Bool) ?? true

        suspendExecution()
        // `self` is only ever touched by the Apple Event Manager's own serialized dispatch, and
        // this method never reads it again after `return nil` below. The `@unchecked Sendable`
        // conformance above covers the *type*; `nonisolated(unsafe)` is additionally needed here
        // because Swift 6's region-based checker still flags a plain `Sendable` value used both
        // before and after an `await` inside the same task as a potential race — asserting that
        // away is exactly what a human already reasoning about "single dispatcher, no reentry"
        // is for.
        nonisolated(unsafe) let command = self
        Task {
            do {
                let output = try await AutomationService.transcribe(
                    fileURL: fileURL,
                    format: format,
                    includeSpeakerLabels: includeSpeakerLabels
                )
                command.resumeExecution(withResult: output as NSString)
            } catch let error as AutomationError {
                command.fail(error)
                command.resumeExecution(withResult: nil)
            } catch {
                // Codex round-1 Finding 6: never surface a raw error's `localizedDescription` —
                // sanitize it (and log the real one privately) even for this catch-all case.
                command.fail(AutomationErrorSanitizer.processingFailure(error, context: "transcribe"))
                command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    /// The sdef declares the direct parameter as `type="file"`; Cocoa Scripting bridges that to
    /// an `NSURL`/`URL` file reference. Codex round-1 Finding 2: a bare path STRING is a weaker
    /// authority signal than a transferred file reference (it never went through the sender's own
    /// file-specifier resolution), so it's deliberately no longer accepted here — only an actual
    /// file reference is. `AutomationFileAuthorization`'s canonical-path containment check is the
    /// real authority boundary regardless, but this keeps the input itself as strong as possible.
    nonisolated static func resolveFileURL(_ directParameter: Any?) -> URL? {
        if let url = directParameter as? URL { return url }
        if let nsURL = directParameter as? NSURL { return nsURL as URL }
        return nil
    }

    private func fail(_ error: AutomationError) {
        scriptErrorNumber = error.appleScriptErrorCode
        scriptErrorString = error.errorDescription
    }
}
