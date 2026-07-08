import Foundation

enum STTEngineKind: String, CaseIterable, Codable {
    case whisperKit
    case cloud
}

enum LLMProviderKind: String, CaseIterable, Codable {
    case anthropic
    case openAICompatible
}

/// Persisted, non-secret app settings. Backed by UserDefaults (simplest storage that fits;
/// see ponytail rung 2/3 — no need for a settings file or DB table for a handful of scalars).
/// Secrets (API keys) never live here — see Keychain.swift.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// The push-to-talk hotkey: modifier chord and/or non-modifier key. Persisted as JSON;
    /// legacy single-modifier installs (pre-HotKeySpec `hotKeyDeviceMask`) are migrated in
    /// `init` so an existing assignment keeps working.
    @Published var hotKeySpec: HotKeySpec {
        didSet {
            if let data = try? JSONEncoder().encode(hotKeySpec) {
                defaults.set(data, forKey: Keys.hotKeySpec)
            }
        }
    }

    @Published var sttEngine: STTEngineKind {
        didSet { defaults.set(sttEngine.rawValue, forKey: Keys.sttEngine) }
    }
    @Published var cloudSTTBaseURL: String {
        didSet { defaults.set(cloudSTTBaseURL, forKey: Keys.cloudSTTBaseURL) }
    }

    @Published var llmProvider: LLMProviderKind {
        didSet { defaults.set(llmProvider.rawValue, forKey: Keys.llmProvider) }
    }
    @Published var cloudLLMBaseURL: String {
        didSet { defaults.set(cloudLLMBaseURL, forKey: Keys.cloudLLMBaseURL) }
    }
    @Published var cloudLLMModel: String {
        didSet { defaults.set(cloudLLMModel, forKey: Keys.cloudLLMModel) }
    }

    @Published var activeTemplateID: String {
        didSet { defaults.set(activeTemplateID, forKey: Keys.activeTemplateID) }
    }

    /// CoreAudio UID of the input device to capture from. nil means "System default" — the
    /// UID (not AudioDeviceID) is persisted since device ids can change across reboots.
    @Published var microphoneDeviceUID: String? {
        didSet { defaults.set(microphoneDeviceUID, forKey: Keys.microphoneDeviceUID) }
    }

    /// Raw, user-typed vocabulary text (one term per line) — the source of truth backing the
    /// Settings TextEditor. Persisted as-typed so re-opening Settings shows exactly what the
    /// user last entered, including blank lines mid-edit. Hard-clamped to
    /// `maxVocabularyRawTextLength` UTF-8 bytes (via `clampVocabularyRawText`) on every set so
    /// UserDefaults/SwiftUI never hold an arbitrarily large paste while `boundedVocabulary` does
    /// its own bounding — see Round 2 Codex finding 1. The clamp is byte-based, not
    /// `String.count`-based, since combining-mark-heavy input can stay under the character count
    /// while its UTF-8 size is huge — see Round 4 Codex finding. Swift does NOT re-invoke
    /// `didSet` for an assignment made from inside the same observer, so the oversized branch
    /// persists the clamped value explicitly instead of relying on re-entry — see Round 3 Codex
    /// finding.
    @Published var vocabularyText: String {
        didSet {
            guard vocabularyText.utf8.count <= Self.maxVocabularyRawTextLength else {
                let clamped = Self.clampVocabularyRawText(vocabularyText)
                vocabularyText = clamped
                defaults.set(clamped, forKey: Keys.vocabularyText)
                return
            }
            defaults.set(vocabularyText, forKey: Keys.vocabularyText)
        }
    }

    /// Normalized vocabulary derived from `vocabularyText` — see `boundedVocabulary`. This is
    /// what STT bias and the post-processor prompt actually consume — see
    /// WhisperKitEngine/CloudSTTEngine/PostProcessor.swift. Consumers must not re-clamp; the
    /// bound is enforced once, here.
    var vocabulary: [String] { Self.boundedVocabulary(vocabularyText).kept }

    /// (kept, total) when bounding actually dropped/truncated terms, nil otherwise — drives the
    /// Settings UI footer warning (SettingsView.swift, Vocabulary section).
    var vocabularyTruncation: (kept: Int, total: Int)? {
        let (kept, total) = Self.boundedVocabulary(vocabularyText)
        return kept.count < total ? (kept.count, total) : nil
    }

    /// Hard ceiling on persisted raw vocabulary input, in UTF-8 bytes (not `String.count`
    /// grapheme clusters — combining-mark-heavy input can stay under a character count limit
    /// while its UTF-8 size is huge, same reasoning as `maxVocabularyCharacterBudget` below) —
    /// independent of the term bounds below, this keeps `vocabularyText` itself from growing
    /// unboundedly. See Round 2 Codex finding 1, Round 4 Codex finding.
    nonisolated static let maxVocabularyRawTextLength = 20_000
    /// Max terms kept after bounding. WhisperKit's prompt window is ~224 tokens; this and
    /// `maxVocabularyCharacterBudget` keep the injected vocabulary well under provider limits
    /// (WhisperKit promptTokens, cloud STT multipart `prompt`, LLM system instructions).
    nonisolated static let maxVocabularyTerms = 100
    /// Max total UTF-8 bytes across kept terms (as joined by ", "). UTF-8 bytes, not grapheme
    /// clusters (`String.count`) — a combining-mark-heavy term can be one grapheme cluster and
    /// dozens of bytes, so grapheme count is not a reliable size bound. See Round 2 Codex
    /// finding 2.
    nonisolated static let maxVocabularyCharacterBudget = 600
    /// Terms whose UTF-8 byte length exceeds this are dropped outright rather than truncated
    /// mid-word. See Round 2 Codex finding 2.
    nonisolated static let maxVocabularyTermLength = 50

    /// Clamps raw vocabulary text to `maxVocabularyRawTextLength` UTF-8 bytes, cutting only at a
    /// `Character` (grapheme cluster) boundary so the result is always valid text — never a
    /// split combining sequence. `String.count` is not a safe size proxy here: combining-mark-
    /// heavy input can be far under the character limit while its UTF-8 byte size is huge (same
    /// reasoning as the per-term byte bound in `boundedVocabulary`) — see Round 4 Codex finding.
    /// Walks characters in order, accumulating UTF-8 byte length, and stops before the first
    /// character that would push the total over the limit — so the scan itself is bounded by
    /// however many characters fit under the byte budget, not by the (possibly much larger)
    /// input length.
    nonisolated static func clampVocabularyRawText(_ s: String) -> String {
        guard s.utf8.count > maxVocabularyRawTextLength else { return s }
        var byteCount = 0
        var cutIndex = s.startIndex
        for index in s.indices {
            let charByteCount = s[index].utf8.count
            guard byteCount + charByteCount <= maxVocabularyRawTextLength else { break }
            byteCount += charByteCount
            cutIndex = s.index(after: index)
        }
        return String(s[..<cutIndex])
    }

    /// Single-pass trim/normalize/validate/dedupe/bound over `vocabularyText`'s lines:
    /// - trims whitespace, drops empty lines
    /// - NFC-normalizes each term (`precomposedStringWithCanonicalMapping`) and rejects it
    ///   outright if it contains control characters or exceeds `maxVocabularyTermLength` UTF-8
    ///   bytes, *before* it's ever inserted into the dedupe set — see Round 2 Codex finding 2
    /// - case-insensitive dedupes on the normalized term, first spelling wins
    /// - keeps terms in user order until either `maxVocabularyTerms` or
    ///   `maxVocabularyCharacterBudget` (joined UTF-8 byte budget) would be exceeded
    ///
    /// Once that cap is hit, scanning stops doing the above work entirely: remaining non-empty
    /// lines are only counted (not normalized, validated, deduped, or stored) so a
    /// pathologically large `vocabularyText` can't force an unbounded scan-and-retain before
    /// bounding kicks in — see Round 2 Codex finding 1. `total` is therefore exact for input
    /// that fits under the cap, and a cheap upper-bound (non-empty-line) count once it doesn't;
    /// either way `kept.count < total` still reliably signals truncation for the UI.
    nonisolated static func boundedVocabulary(_ raw: String) -> (kept: [String], total: Int) {
        var seenLowercased = Set<String>()
        var kept: [String] = []
        var byteBudget = 0
        var total = 0
        var capped = false

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if capped {
                total += 1
                continue
            }

            let normalized = trimmed.precomposedStringWithCanonicalMapping
            guard !normalized.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { continue }
            let byteLength = normalized.utf8.count
            guard byteLength <= maxVocabularyTermLength else { continue }
            guard seenLowercased.insert(normalized.lowercased()).inserted else { continue }

            total += 1
            let increment = kept.isEmpty ? byteLength : byteLength + 2 // ", " separator
            if kept.count < maxVocabularyTerms && byteBudget + increment <= maxVocabularyCharacterBudget {
                kept.append(normalized)
                byteBudget += increment
            } else {
                capped = true
            }
        }
        return (kept, total)
    }

    nonisolated static func normalizeVocabulary(_ raw: String) -> [String] {
        boundedVocabulary(raw).kept
    }

    private enum Keys {
        static let hotKeySpec = "hotKeySpec"
        /// Legacy (read-only, for migration): single-modifier NX device mask bit.
        static let legacyHotKeyDeviceMask = "hotKeyDeviceMask"
        static let sttEngine = "sttEngine"
        static let cloudSTTBaseURL = "cloudSTTBaseURL"
        static let llmProvider = "llmProvider"
        static let cloudLLMBaseURL = "cloudLLMBaseURL"
        static let cloudLLMModel = "cloudLLMModel"
        static let activeTemplateID = "activeTemplateID"
        static let microphoneDeviceUID = "microphoneDeviceUID"
        static let vocabularyText = "vocabularyText"
    }

    private init() {
        if let data = defaults.data(forKey: Keys.hotKeySpec),
           let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) {
            hotKeySpec = spec
        } else if let legacyMask = defaults.object(forKey: Keys.legacyHotKeyDeviceMask) as? Int64, legacyMask != 0 {
            // Migrate a pre-HotKeySpec single-modifier assignment (e.g. "Left ⌃").
            hotKeySpec = HotKeySpec(modifiers: UInt64(bitPattern: legacyMask), keyCode: nil)
        } else {
            hotKeySpec = .default
        }
        sttEngine = STTEngineKind(rawValue: defaults.string(forKey: Keys.sttEngine) ?? "") ?? .whisperKit
        cloudSTTBaseURL = defaults.string(forKey: Keys.cloudSTTBaseURL) ?? "https://api.openai.com/v1"
        llmProvider = LLMProviderKind(rawValue: defaults.string(forKey: Keys.llmProvider) ?? "") ?? .anthropic
        cloudLLMBaseURL = defaults.string(forKey: Keys.cloudLLMBaseURL) ?? "https://api.anthropic.com/v1"
        cloudLLMModel = defaults.string(forKey: Keys.cloudLLMModel) ?? "claude-sonnet-4-5"
        activeTemplateID = defaults.string(forKey: Keys.activeTemplateID) ?? Template.defaultID
        microphoneDeviceUID = defaults.string(forKey: Keys.microphoneDeviceUID)
        // Direct init assignment doesn't trigger `didSet`'s clamp, so clamp explicitly here too
        // — covers a value persisted before maxVocabularyRawTextLength existed. Also
        // re-persist the clamped value so UserDefaults doesn't keep holding the oversized
        // string across relaunches — see Round 3 Codex finding. Byte-based (not `String.count`)
        // for the same reason as the `didSet` clamp — see Round 4 Codex finding.
        let storedVocabularyText = defaults.string(forKey: Keys.vocabularyText) ?? ""
        if storedVocabularyText.utf8.count > Self.maxVocabularyRawTextLength {
            let clamped = Self.clampVocabularyRawText(storedVocabularyText)
            vocabularyText = clamped
            defaults.set(clamped, forKey: Keys.vocabularyText)
        } else {
            vocabularyText = storedVocabularyText
        }
    }
}
