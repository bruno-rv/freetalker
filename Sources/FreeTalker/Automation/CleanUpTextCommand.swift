import Foundation

/// Cocoa Scripting entry point for `FreeTalker.sdef`'s `clean up` command
/// (BRAINSTORM_AUTOMATION_SURFACE.md capability 2). No microphone, no recording, no permissions —
/// a direct call into `AutomationService.cleanUpText`, which resolves the named Template from
/// `TemplateStore` and calls `PostProcessor.process(_:)` exactly as the rest of the app does. See
/// `TranscribeFileCommand`'s doc comment for why this suspends the AppleEvent reply instead of
/// blocking a thread.
final class CleanUpTextCommand: NSScriptCommand, @unchecked Sendable {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String else {
            fail(.invalidInput("Provide the text to clean up."))
            return nil
        }
        guard let templateName = (evaluatedArguments?["templateName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !templateName.isEmpty else {
            fail(.invalidInput("Provide the name of the Template to apply, using template."))
            return nil
        }

        suspendExecution()
        // See `TranscribeFileCommand`'s matching comment for why `nonisolated(unsafe)` is needed
        // here despite the class-level `@unchecked Sendable`.
        nonisolated(unsafe) let command = self
        Task {
            do {
                let output = try await AutomationService.cleanUpText(text, templateName: templateName)
                command.resumeExecution(withResult: output as NSString)
            } catch let error as AutomationError {
                command.fail(error)
                command.resumeExecution(withResult: nil)
            } catch {
                command.fail(.pipelineFailed(error.localizedDescription))
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
