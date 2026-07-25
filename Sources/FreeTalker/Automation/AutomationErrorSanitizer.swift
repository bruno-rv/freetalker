import Foundation
import os

/// Codex round-1 Finding 6: a downstream pipeline error's own `localizedDescription` must never
/// cross the automation boundary verbatim — a missing WhisperKit model artifact's message carries
/// its full `/Users/...` path, and a cloud post-processing failure exposes provider selection and
/// HTTP status. Every mapping here logs the real error privately (Console.app / `log show` only)
/// and returns a fixed, safe `AutomationError` instead.
enum AutomationErrorSanitizer {
    private static let logger = Logger(subsystem: "org.freetalker.app", category: "automation")

    /// Generic pipeline-failure mapping: logs `error` privately, returns the fixed
    /// `.processingFailed` case. `context` is a literal (never interpolated user data) naming the
    /// call site for the private log line.
    static func processingFailure(_ error: Error, context: StaticString) -> AutomationError {
        processingFailure(message: String(describing: error), context: context)
    }

    /// Same mapping as above for call sites that already have a plain description (e.g. a
    /// `JobFailure.message`) rather than a thrown `Error`.
    static func processingFailure(message: String, context: StaticString) -> AutomationError {
        logger.error("\(context, privacy: .public) failed: \(message, privacy: .private)")
        return .processingFailed
    }

    /// `clean up`'s processor-specific mapping: `AppleFMProcessor.FMError.unavailable` (on-device
    /// model not ready) and `.translationUnsupported` (a cloud-only capability — Finding 1) each
    /// get their own distinct, sanitized case so a caller can branch; anything else falls back to
    /// the generic mapping above.
    static func processorFailure(_ error: Error) -> AutomationError {
        if let fmError = error as? AppleFMProcessor.FMError {
            switch fmError {
            case .unavailable: return .modelUnavailable
            case .translationUnsupported: return .cloudCapabilityUnavailable
            }
        }
        return processingFailure(error, context: "clean up")
    }
}
