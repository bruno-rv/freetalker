import Foundation

/// Cocoa Scripting entry point for `FreeTalker.sdef`'s `clean up` command
/// (BRAINSTORM_AUTOMATION_SURFACE.md). No microphone, no recording, no permissions — a direct
/// call into `AutomationService.cleanUpText`, which resolves the named Template from
/// `TemplateStore` and always runs it through FreeTalker's on-device processor (never cloud — see
/// `AutomationService.cleanUpText`'s doc comment).
///
/// Suspends the AppleEvent reply (`suspendExecution`/`resumeExecution(withResult:)`) instead of
/// blocking a thread: `AutomationService` needs the main actor (it goes through
/// `AppCoordinator`/`AppSettings`), and Apple Event dispatch itself runs there too, so a thread
/// that actually blocked while resuming that same work would deadlock. The suspend/resume pair is
/// exactly what Cocoa Scripting has offered slow commands since it's an ordinary async reply, not
/// a workaround.
final class CleanUpTextCommand: NSScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String else {
            fail(.invalidInput("Provide the text to clean up."))
            return nil
        }
        // Codex round-1 Finding 3: reject empty/oversized text and an oversized template name
        // BEFORE `suspendExecution()` — cheap, synchronous checks that never let a bad call start
        // the expensive (suspended, reentrant) work below.
        do {
            try AutomationTextValidation.validateCleanUpText(text)
        } catch let error as AutomationError {
            fail(error)
            return nil
        } catch {
            fail(.invalidInput("Provide the text to clean up."))
            return nil
        }
        guard let rawTemplateName = evaluatedArguments?["templateName"] as? String else {
            fail(.invalidInput("Provide the name of the Template to apply, using template."))
            return nil
        }
        // Codex round-2 Finding 3: check the RAW (untrimmed) byte count before trimming — an
        // enormous template name must never reach `trimmingCharacters(in:)`'s scan/allocation.
        do {
            try AutomationTextValidation.validateTemplateName(rawTemplateName)
        } catch let error as AutomationError {
            fail(error)
            return nil
        } catch {
            fail(.invalidInput("The template name is too long."))
            return nil
        }
        let templateName = rawTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !templateName.isEmpty else {
            fail(.invalidInput("Provide the name of the Template to apply, using template."))
            return nil
        }

        // Codex round-1 Finding 3: Cocoa Scripting suspended commands are explicitly reentrant —
        // claim the single in-flight slot BEFORE suspending, so a busy rejection never suspends
        // and never runs concurrent prompt construction/network work.
        guard AutomationConcurrencyGate.beginCleanUp() else {
            fail(.busy)
            return nil
        }

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
            // Codex round-3 additional finding: release the slot BEFORE `resumeExecution`, never
            // in a `defer` that ran after it — the old ordering could let a new Apple Event see a
            // stale `.busy` for a moment after this one had already replied, and released the slot
            // from whatever (possibly non-main) executor this task's body happened to be running
            // on when the `defer` fired, racing a new `beginCleanUp()` on the main thread without
            // a lock. `AutomationConcurrencyGate` is now lock-protected regardless, but the
            // ordering fix is what actually keeps `.busy` truthful.
            do {
                let output = try await AutomationService.cleanUpText(text, templateName: templateName)
                AutomationConcurrencyGate.endCleanUp()
                command.resumeExecution(withResult: output as NSString)
            } catch let error as AutomationError {
                AutomationConcurrencyGate.endCleanUp()
                command.fail(error)
                command.resumeExecution(withResult: nil)
            } catch {
                // Codex round-1 Finding 6: never surface a raw error's `localizedDescription` —
                // sanitize it (and log the real one privately) even for this catch-all case.
                AutomationConcurrencyGate.endCleanUp()
                command.fail(AutomationErrorSanitizer.processingFailure(error, context: "clean up"))
                command.resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    private func fail(_ error: AutomationError) {
        scriptErrorNumber = error.appleScriptErrorCode
        scriptErrorString = error.errorDescription
    }
}
