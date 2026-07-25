import Foundation

/// Cocoa Scripting entry point for `FreeTalker.sdef`'s `clean up` command
/// (BRAINSTORM_AUTOMATION_SURFACE.md capability 2). No microphone, no recording, no permissions —
/// a direct call into `AutomationService.cleanUpText`, which resolves the named Template from
/// `TemplateStore` and always runs it through FreeTalker's on-device processor (never cloud — see
/// `AutomationService.cleanUpText`'s doc comment). See `TranscribeFileCommand`'s doc comment for
/// why this suspends the AppleEvent reply instead of blocking a thread.
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
        // See `TranscribeFileCommand`'s matching comment for why `nonisolated(unsafe)` is needed
        // here despite the class-level `@unchecked Sendable`.
        nonisolated(unsafe) let command = self
        Task {
            // Codex round-3 additional finding: release the slot BEFORE `resumeExecution`, never
            // in a `defer` that ran after it — see `TranscribeFileCommand`'s matching comment.
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
