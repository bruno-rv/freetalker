import Foundation

/// The real work behind `FreeTalker.sdef`'s `clean up` command (BRAINSTORM_AUTOMATION_SURFACE.md).
/// Kept separate from the `NSScriptCommand` subclass so it's callable (and its errors
/// inspectable) without any Apple Event/Cocoa Scripting machinery, and so the command class stays
/// a thin adapter over it. Calls the same `PostProcessor.process(_:)` contract the UI uses, but
/// ALWAYS through `AppleFMProcessor` (Apple's on-device Foundation Models), never
/// `AppCoordinator.resolveActiveProcessor()`'s cloud/on-device selection — see the doc comment on
/// `cleanUpText` for why.
@MainActor
enum AutomationService {
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
    /// today — this sdef exposes no language parameter). There is deliberately no `AutomationError`
    /// case reserved for that today-unreachable path — see `AutomationErrorSanitizer.processorFailure`.
    /// If a cloud-only capability is ever added to the sdef, add its own distinct, non-silent
    /// `AutomationError` case at that point.
    static func cleanUpText(_ text: String, templateName: String) async throws -> String {
        try AutomationGate.checkEnabled(AppSettings.shared.automationEnabled)
        let template: Template
        switch TemplateStore.resolveTemplate(named: templateName, in: TemplateStore.shared.templates) {
        case .found(let match):
            template = match
        case .notFound:
            throw AutomationError.unknownTemplate(templateName)
        case .ambiguous:
            // Codex round-6 finding: two Templates sharing this exact name (e.g. after the
            // whitespace-canonicalization migration in `TemplateStore.init` collapses previously-
            // distinct names onto the same one) must never be resolved by silently picking one —
            // see `TemplateStore.resolveTemplate`'s doc comment.
            throw AutomationError.ambiguousTemplateName(templateName)
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
}
