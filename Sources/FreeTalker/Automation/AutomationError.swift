import Foundation

/// Errors the automation surface (`FreeTalker.sdef`'s `clean up` command — see
/// BRAINSTORM_AUTOMATION_SURFACE.md) returns to its caller as AppleEvent errors, so a Shortcut or
/// `osascript` script can branch on them instead of silently getting nothing back.
///
/// Codex round-1 Finding 6: every case's `errorDescription` is a FIXED, sanitized string — never
/// the underlying pipeline error's own `localizedDescription` verbatim (that can carry a full
/// `/Users/...` filesystem path from a missing model artifact, or a cloud provider name/HTTP
/// status). The real error is logged privately instead — see `AutomationErrorSanitizer`.
enum AutomationError: LocalizedError, Equatable {
    /// Settings → Privacy → Automation is off. The consent gate — see `AppSettings.automationEnabled`.
    case automationDisabled
    /// No Template named this exists — never silently substituted for a default.
    case unknownTemplate(String)
    /// The on-device model (Apple's Foundation Models framework) isn't available on this Mac
    /// right now. `clean up` never falls back to cloud — see `AutomationService.cleanUpText`.
    case modelUnavailable
    /// The underlying pipeline failed. The real error is logged privately, never returned here —
    /// see `AutomationErrorSanitizer`.
    case processingFailed
    /// A malformed or missing argument the AppleEvent layer itself didn't already reject.
    case invalidInput(String)
    /// `clean up`'s text is empty (or whitespace-only) — Codex round-1 Finding 3.
    case emptyText
    /// `clean up`'s text exceeds automation's byte cap — Codex round-1 Finding 3.
    case textTooLarge
    /// Another automation request is already in flight; Cocoa Scripting commands are reentrant,
    /// so this is an explicit single-in-flight limit — Codex round-1 Finding 3.
    case busy

    var errorDescription: String? {
        switch self {
        case .automationDisabled:
            return "Automation is turned off. Enable it in FreeTalker → Settings → Privacy → Automation."
        case .unknownTemplate(let name):
            return "No FreeTalker Template named \"\(name)\" was found."
        case .modelUnavailable:
            return "On-device processing isn't available on this Mac right now. Try again once Apple Intelligence is enabled and its model is downloaded."
        case .processingFailed:
            return "FreeTalker couldn't complete this request. Check FreeTalker's logs for details."
        case .invalidInput(let message):
            return message
        case .emptyText:
            return "Provide non-empty text to clean up."
        case .textTooLarge:
            return "This text is too long for automation to clean up."
        case .busy:
            return "FreeTalker is already handling another automation request. Try again in a moment."
        }
    }

    /// Positive, app-specific range chosen to stay clear of Apple's own (mostly negative)
    /// AppleEvent `OSErr`/`OSStatus` codes, so a caller can reliably tell a FreeTalker automation
    /// failure apart from a system-level Apple Event error.
    var appleScriptErrorCode: Int {
        switch self {
        case .automationDisabled: return 20001
        case .unknownTemplate: return 20003
        case .processingFailed: return 20004
        case .invalidInput: return 20006
        case .modelUnavailable: return 20007
        case .emptyText: return 20013
        case .textTooLarge: return 20014
        case .busy: return 20015
        }
    }
}

/// The consent gate itself (BRAINSTORM_AUTOMATION_SURFACE.md "Security model"): `clean up`
/// refuses outright unless the user has explicitly turned this on. Pure and `nonisolated` so it's
/// testable without touching `AppSettings`'s `@MainActor` isolation.
enum AutomationGate {
    static func checkEnabled(_ enabled: Bool) throws {
        guard enabled else { throw AutomationError.automationDisabled }
    }
}
