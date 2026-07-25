import Foundation

/// Errors the automation surface (`FreeTalker.sdef`'s `transcribe`/`clean up` commands — see
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
    /// `transcribe`'s file isn't one of the formats the Imports window accepts.
    case unsupportedFileType
    /// No Template named this exists — never silently substituted for a default.
    case unknownTemplate(String)
    /// The on-device model (Apple's Foundation Models framework) isn't available on this Mac
    /// right now. `clean up` never falls back to cloud — see `AutomationService.cleanUpText`.
    case modelUnavailable
    /// The request needs cloud processing (e.g. output-language translation) and automation never
    /// uses cloud, ever — see Codex round-1 Finding 1. Never silently degraded to something else.
    case cloudCapabilityUnavailable
    /// The underlying pipeline failed. The real error is logged privately, never returned here —
    /// see `AutomationErrorSanitizer`.
    case processingFailed
    /// The job was cancelled from the Imports window while automation was waiting on it.
    case cancelled
    /// A malformed or missing argument the AppleEvent layer itself didn't already reject.
    case invalidInput(String)
    /// No automation folder is configured in Settings → Privacy → Automation. `transcribe`
    /// refuses every file until one is chosen — see Codex round-1 Finding 2.
    case automationFolderNotConfigured
    /// The requested file's canonical (symlink-resolved) path isn't inside the configured
    /// automation folder. Codex round-1 Finding 2 — the automation toggle alone grants no
    /// per-file authority.
    case fileNotAuthorized
    /// The configured Automation folder's security-scoped bookmark is missing, unreadable, stale,
    /// or no longer resolves to a real directory — Codex round-2 Finding 1. A `UserDefaults` path
    /// string is never re-trusted as the authority in this case; the user must choose the folder
    /// again so a fresh bookmark is created.
    case automationFolderUnavailable
    /// The path isn't a regular file (a FIFO, device node, directory, or symlink) — Codex round-1
    /// Finding 4.
    case unsupportedMediaFile
    /// The source file or its media duration exceeds automation's bounds — Codex round-1 Finding 4.
    case mediaTooLarge
    /// `clean up`'s text is empty (or whitespace-only) — Codex round-1 Finding 3.
    case emptyText
    /// `clean up`'s text exceeds automation's byte cap — Codex round-1 Finding 3.
    case textTooLarge
    /// Another automation request is already in flight; Cocoa Scripting commands are reentrant,
    /// so this is an explicit single-in-flight limit — Codex round-1 Finding 3.
    case busy
    /// The request exceeded automation's app-side deadline and was cancelled — Codex round-1
    /// Finding 7.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .automationDisabled:
            return "Automation is turned off. Enable it in FreeTalker → Settings → Privacy → Automation."
        case .unsupportedFileType:
            return "FreeTalker can't transcribe this file. Choose a WAV, M4A, MP3, MP4, or MOV file."
        case .unknownTemplate(let name):
            return "No FreeTalker Template named \"\(name)\" was found."
        case .modelUnavailable:
            return "On-device processing isn't available on this Mac right now. Try again once Apple Intelligence is enabled and its model is downloaded."
        case .cloudCapabilityUnavailable:
            return "This request needs cloud processing, which automation never uses. It isn't available through automation."
        case .processingFailed:
            return "FreeTalker couldn't complete this request. Check the Imports window, or FreeTalker's logs, for details."
        case .cancelled:
            return "The job was cancelled."
        case .invalidInput(let message):
            return message
        case .automationFolderNotConfigured:
            return "Choose an Automation folder in FreeTalker → Settings → Privacy → Automation before transcribing files."
        case .fileNotAuthorized:
            return "FreeTalker can only transcribe files inside the folder chosen in Settings → Privacy → Automation."
        case .automationFolderUnavailable:
            return "The Automation folder chosen in Settings → Privacy → Automation is missing or was replaced. Choose it again."
        case .unsupportedMediaFile:
            return "FreeTalker can only transcribe a regular audio or video file — not a special file, device, or symbolic link."
        case .mediaTooLarge:
            return "This file is too large, or too long, for automation to transcribe."
        case .emptyText:
            return "Provide non-empty text to clean up."
        case .textTooLarge:
            return "This text is too long for automation to clean up."
        case .busy:
            return "FreeTalker is already handling another automation request. Try again in a moment."
        case .timedOut:
            return "This request took too long and was cancelled."
        }
    }

    /// Positive, app-specific range chosen to stay clear of Apple's own (mostly negative)
    /// AppleEvent `OSErr`/`OSStatus` codes, so a caller can reliably tell a FreeTalker automation
    /// failure apart from a system-level Apple Event error.
    var appleScriptErrorCode: Int {
        switch self {
        case .automationDisabled: return 20001
        case .unsupportedFileType: return 20002
        case .unknownTemplate: return 20003
        case .processingFailed: return 20004
        case .cancelled: return 20005
        case .invalidInput: return 20006
        case .modelUnavailable: return 20007
        case .cloudCapabilityUnavailable: return 20008
        case .automationFolderNotConfigured: return 20009
        case .fileNotAuthorized: return 20010
        case .unsupportedMediaFile: return 20011
        case .mediaTooLarge: return 20012
        case .emptyText: return 20013
        case .textTooLarge: return 20014
        case .busy: return 20015
        case .timedOut: return 20016
        case .automationFolderUnavailable: return 20017
        }
    }
}

/// The consent gate itself (BRAINSTORM_AUTOMATION_SURFACE.md "Security model"): both automation
/// commands refuse outright unless the user has explicitly turned this on. Pure and `nonisolated`
/// so it's testable without touching `AppSettings`'s `@MainActor` isolation.
enum AutomationGate {
    static func checkEnabled(_ enabled: Bool) throws {
        guard enabled else { throw AutomationError.automationDisabled }
    }
}

/// Maps `FreeTalker.sdef`'s `format style` enumeration's cocoa string values to `TranscriptFormat`.
/// The AppleEvent layer already rejects anything outside the sdef's four enumerators before a
/// command ever sees it, so an absent parameter (the optional default) is the only `nil` case in
/// practice — resolved to plain text, matching the sdef's documented default.
enum AutomationTranscriptFormat {
    static func parse(_ raw: String?) -> TranscriptFormat {
        switch raw {
        case "markdown": return .markdown
        case "srt": return .srt
        case "vtt": return .vtt
        default: return .plainText
        }
    }
}
