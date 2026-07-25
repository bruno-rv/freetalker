import Foundation

/// Errors the automation surface (`FreeTalker.sdef`'s `transcribe`/`clean up` commands — see
/// BRAINSTORM_AUTOMATION_SURFACE.md) returns to its caller as AppleEvent errors, so a Shortcut or
/// `osascript` script can branch on them instead of silently getting nothing back.
enum AutomationError: LocalizedError, Equatable {
    /// Settings → Privacy → Automation is off. The consent gate — see `AppSettings.automationEnabled`.
    case automationDisabled
    /// `transcribe`'s file isn't one of the formats the Imports window accepts.
    case unsupportedFileType
    /// No Template named this exists — never silently substituted for a default.
    case unknownTemplate(String)
    /// The underlying pipeline (transcription job or post-processor) threw or failed; `String` is
    /// its own message, e.g. a missing/undownloadable speech model surfaces here verbatim.
    case pipelineFailed(String)
    /// The job was cancelled from the Imports window while automation was waiting on it.
    case cancelled
    /// A malformed or missing argument the AppleEvent layer itself didn't already reject.
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .automationDisabled:
            return "Automation is turned off. Enable it in FreeTalker → Settings → Privacy → Automation."
        case .unsupportedFileType:
            return "FreeTalker can't transcribe this file. Choose a WAV, M4A, MP3, MP4, or MOV file."
        case .unknownTemplate(let name):
            return "No FreeTalker Template named \"\(name)\" was found."
        case .pipelineFailed(let message):
            return message
        case .cancelled:
            return "The job was cancelled."
        case .invalidInput(let message):
            return message
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
        case .pipelineFailed: return 20004
        case .cancelled: return 20005
        case .invalidInput: return 20006
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
