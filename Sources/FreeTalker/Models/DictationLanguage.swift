import Foundation

/// The curated pool of spoken languages a user can select into `AppSettings.dictationLanguages`
/// (F5) — canonical **Whisper STT** codes, distinct from `OutputLanguage`/`TranslationTarget`'s
/// persisted codes (which use e.g. `"zh-Hans"` for Chinese where Whisper uses `"zh"`). This is
/// the ONE explicit STT-code ↔ display-name ↔ output-language mapping table (PLAN.md F5.2) — STT
/// codes never leak into output-language persistence and vice versa; every other consumer
/// (normalizer, presentation helper, UI pickers) is built on top of this enum rather than
/// duplicating the code/name list.
enum DictationLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case portuguese = "pt"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case mandarinChinese = "zh"
    case hindi = "hi"
    case standardArabic = "ar"

    var displayName: String {
        switch self {
        case .english: "English"
        case .portuguese: "Portuguese"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .mandarinChinese: "Mandarin Chinese"
        case .hindi: "Hindi"
        case .standardArabic: "Standard Arabic"
        }
    }

    /// The matching `OutputLanguage`/`TranslationTarget` persisted rawValue — the only place this
    /// STT code ↔ output code translation happens. Every case here has a corresponding
    /// `OutputLanguage` case; this is a total mapping, not a partial one.
    var outputLanguageCode: String {
        switch self {
        case .mandarinChinese: "zh-Hans"
        default: rawValue
        }
    }

    var outputLanguage: OutputLanguage {
        OutputLanguage(rawValue: outputLanguageCode) ?? .sameAsSpoken
    }

    var translationTarget: TranslationTarget? {
        TranslationTarget(rawValue: outputLanguageCode)
    }
}

/// Single source feeding every spoken-language selector (Settings pin picker, per-app rule
/// picker, menu-bar selector, HUD/floating-controls selector, launcher) — PLAN.md F5.5. No
/// selector list is hardcoded independently; all read the app's *configured* set through here.
enum DictationLanguagePresentation {
    /// `(code, label)` pairs for the given configured codes, in `DictationLanguage.allCases`
    /// (curated) order — unrecognized codes are dropped rather than shown with a blank label.
    nonisolated static func options(for codes: [String]) -> [(code: String, label: String)] {
        let configured = Set(codes)
        return DictationLanguage.allCases
            .filter { configured.contains($0.rawValue) }
            .map { (code: $0.rawValue, label: $0.displayName) }
    }

    /// Display name for a single code, falling back to the raw code itself if unrecognized (e.g.
    /// stale persisted data) rather than showing nothing.
    nonisolated static func displayName(for code: String) -> String {
        DictationLanguage(rawValue: code)?.displayName ?? code
    }
}
