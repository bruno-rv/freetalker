import Foundation

enum STTEngineKind: String, CaseIterable, Codable {
    case whisperKit
    case cloud
}

enum LLMProviderKind: String, CaseIterable, Codable {
    case anthropic
    case ollama
    case openAICompatible
}

/// Known (base URL, model) default for a provider — `nil` for a field means that provider has
/// no known default (e.g. `openAICompatible`, an arbitrary user endpoint). See
/// `AppSettings.resolveProviderDefaults`.
struct LLMProviderDefault: Equatable {
    let baseURL: String?
    let model: String?
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

    /// The optional Redo Last hotkey (CONTEXT.md "Redo Last"): nil = unbound = dormant, the
    /// default. Persisted as JSON in UserDefaults like `hotKeySpec` above, but — since nil is a
    /// meaningful, common state here, unlike `hotKeySpec` which is never unbound — persisting nil
    /// removes the key rather than writing null/absent JSON, so a stale spec never lingers once
    /// the user clears it. See PLAN.md step 7.
    @Published var redoHotKeySpec: HotKeySpec? {
        didSet {
            if let redoHotKeySpec, let data = try? JSONEncoder().encode(redoHotKeySpec) {
                defaults.set(data, forKey: Keys.redoHotKeySpec)
            } else {
                defaults.removeObject(forKey: Keys.redoHotKeySpec)
            }
        }
    }

    @Published var sttEngine: STTEngineKind {
        didSet { defaults.set(sttEngine.rawValue, forKey: Keys.sttEngine) }
    }
    @Published var cloudSTTBaseURL: String {
        didSet { defaults.set(cloudSTTBaseURL, forKey: Keys.cloudSTTBaseURL) }
    }

    /// Whether the HUD shows a live rolling transcript while push-to-talk is held. Default ON.
    /// See PLAN 3 "Settings" — `AppCoordinator.isLivePreviewEnabled` combines this with the
    /// active engine/loaded-model state to decide whether preview actually runs.
    @Published var livePreviewEnabled: Bool {
        didSet { defaults.set(livePreviewEnabled, forKey: Keys.livePreviewEnabled) }
    }

    /// On every change, `cloudLLMBaseURL`/`cloudLLMModel` are re-resolved against the new
    /// provider's known default via `resolveProviderDefaults` — a value that's empty or equals
    /// another provider's known default is swapped for this provider's; a value the user
    /// actually customized is left untouched. See PLAN.md step 2.
    @Published var llmProvider: LLMProviderKind {
        didSet {
            defaults.set(llmProvider.rawValue, forKey: Keys.llmProvider)
            let resolved = Self.resolveProviderDefaults(provider: llmProvider, baseURL: cloudLLMBaseURL, model: cloudLLMModel)
            if resolved.baseURL != cloudLLMBaseURL { cloudLLMBaseURL = resolved.baseURL }
            if resolved.model != cloudLLMModel { cloudLLMModel = resolved.model }
        }
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

    /// Auto-stop cap for a `locked` (hands-free) recording, in minutes — clamped to [1, 60] both
    /// here (on persist) and in `init` (on read), so a stale/out-of-range stored value or a
    /// direct programmatic set can never reach a recording unclamped. Swift does not re-invoke
    /// `didSet` for an assignment made from inside the same observer (same reasoning as
    /// `vocabularyText` above), so the clamped branch persists the clamped value explicitly.
    /// Held (PTT) recordings are unbounded, unaffected. See PLAN.md Amendment B2.
    @Published var handsFreeMaxMinutes: Int {
        didSet {
            let clamped = Self.clampHandsFreeMaxMinutes(handsFreeMaxMinutes)
            guard clamped == handsFreeMaxMinutes else {
                handsFreeMaxMinutes = clamped
                defaults.set(clamped, forKey: Keys.handsFreeMaxMinutes)
                return
            }
            defaults.set(handsFreeMaxMinutes, forKey: Keys.handsFreeMaxMinutes)
        }
    }

    /// Pure [1, 60]-minute clamp for `handsFreeMaxMinutes`. SelfCheck-tested directly.
    nonisolated static func clampHandsFreeMaxMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 1), 60)
    }

    /// Per-app template rules: bundle identifier -> template id. `[String: String]` is a
    /// property-list type UserDefaults stores natively — no JSON encoding needed (unlike
    /// `hotKeySpec` above, which isn't). Consulted by `AppCoordinator.resolveTemplate`; a rule
    /// whose template id no longer exists is not cleaned up here — resolution falls back to the
    /// Active Template instead. See PLAN "App Rules".
    @Published var appRules: [String: String] {
        didSet { defaults.set(appRules, forKey: Keys.appRules) }
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

    /// Known base URL / model per provider — the single source of truth `resolveProviderDefaults`
    /// swaps values against. `openAICompatible` has no known default: it's an arbitrary,
    /// user-supplied endpoint. See PLAN.md step 2.
    nonisolated static let knownProviderDefaults: [LLMProviderKind: LLMProviderDefault] = [
        .anthropic: LLMProviderDefault(baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5"),
        .ollama: LLMProviderDefault(baseURL: "https://ollama.com/v1", model: "gpt-oss:120b"),
        .openAICompatible: LLMProviderDefault(baseURL: nil, model: nil)
    ]

    /// Swaps `baseURL`/`model` to `provider`'s known default when each (whitespace-trimmed)
    /// value is empty, or verbatim-equals a known default belonging to a *different* provider —
    /// a value the user actually customized (matches no known default) is never touched. When
    /// `provider` itself has no known default (`openAICompatible`), a swap clears the field to
    /// "" instead. Idempotent: re-applying to already-resolved values is a no-op. All matching
    /// operates on trimmed values, and the result is the trimmed strings — see PLAN.md step 2,
    /// Round 2/3 Codex findings (defaulting on init too; whitespace variants bypassing matching).
    nonisolated static func resolveProviderDefaults(provider: LLMProviderKind, baseURL: String, model: String) -> (baseURL: String, model: String) {
        let current = knownProviderDefaults[provider] ?? LLMProviderDefault(baseURL: nil, model: nil)
        let allBaseURLs = Set(knownProviderDefaults.values.compactMap(\.baseURL))
        let allModels = Set(knownProviderDefaults.values.compactMap(\.model))

        func resolve(_ value: String, knownValues: Set<String>, currentDefault: String?) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || (knownValues.contains(trimmed) && trimmed != currentDefault) {
                return currentDefault ?? ""
            }
            return trimmed
        }

        return (
            resolve(baseURL, knownValues: allBaseURLs, currentDefault: current.baseURL),
            resolve(model, knownValues: allModels, currentDefault: current.model)
        )
    }

    private enum Keys {
        static let hotKeySpec = "hotKeySpec"
        static let redoHotKeySpec = "redoHotKeySpec"
        /// Legacy (read-only, for migration): single-modifier NX device mask bit.
        static let legacyHotKeyDeviceMask = "hotKeyDeviceMask"
        static let sttEngine = "sttEngine"
        static let cloudSTTBaseURL = "cloudSTTBaseURL"
        static let livePreviewEnabled = "livePreviewEnabled"
        static let llmProvider = "llmProvider"
        static let cloudLLMBaseURL = "cloudLLMBaseURL"
        static let cloudLLMModel = "cloudLLMModel"
        static let activeTemplateID = "activeTemplateID"
        static let handsFreeMaxMinutes = "handsFreeMaxMinutes"
        static let appRules = "appRules"
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
        if let data = defaults.data(forKey: Keys.redoHotKeySpec) {
            redoHotKeySpec = try? JSONDecoder().decode(HotKeySpec.self, from: data)
        } else {
            redoHotKeySpec = nil
        }
        sttEngine = STTEngineKind(rawValue: defaults.string(forKey: Keys.sttEngine) ?? "") ?? .whisperKit
        cloudSTTBaseURL = defaults.string(forKey: Keys.cloudSTTBaseURL) ?? "https://api.openai.com/v1"
        // Default ON — `.object(forKey:)` (not `.bool(forKey:)`) so an unset key is distinguished
        // from an explicit `false`, which `.bool(forKey:)` can't do (it returns false for both).
        livePreviewEnabled = defaults.object(forKey: Keys.livePreviewEnabled) as? Bool ?? true
        // Loaded into locals first, not `self.llmProvider`/`self.cloudLLMBaseURL`/
        // `self.cloudLLMModel` directly: `self` can't be read (even its own not-yet-assigned
        // stored properties) until every stored property is initialized, and
        // `resolveProviderDefaults` needs all three together. No hardcoded base URL/model
        // fallback here — `resolveProviderDefaults` is the single source of truth for provider
        // defaults (an empty value resolves to the current provider's known default, if any).
        // See Round 1 Codex findings 2/4, Round 2 Codex finding 2 (direct init assignment
        // doesn't trigger `llmProvider`'s didSet, so this resolution must also run here, once).
        let loadedProvider = LLMProviderKind(rawValue: defaults.string(forKey: Keys.llmProvider) ?? "") ?? .anthropic
        let rawCloudLLMBaseURL = defaults.string(forKey: Keys.cloudLLMBaseURL) ?? ""
        let rawCloudLLMModel = defaults.string(forKey: Keys.cloudLLMModel) ?? ""
        let resolvedProviderDefaults = Self.resolveProviderDefaults(provider: loadedProvider, baseURL: rawCloudLLMBaseURL, model: rawCloudLLMModel)
        llmProvider = loadedProvider
        cloudLLMBaseURL = resolvedProviderDefaults.baseURL
        cloudLLMModel = resolvedProviderDefaults.model
        if resolvedProviderDefaults.baseURL != rawCloudLLMBaseURL {
            defaults.set(resolvedProviderDefaults.baseURL, forKey: Keys.cloudLLMBaseURL)
        }
        if resolvedProviderDefaults.model != rawCloudLLMModel {
            defaults.set(resolvedProviderDefaults.model, forKey: Keys.cloudLLMModel)
        }
        activeTemplateID = defaults.string(forKey: Keys.activeTemplateID) ?? Template.defaultID
        let storedHandsFreeMaxMinutes = defaults.object(forKey: Keys.handsFreeMaxMinutes) as? Int ?? 5
        handsFreeMaxMinutes = Self.clampHandsFreeMaxMinutes(storedHandsFreeMaxMinutes)
        appRules = defaults.dictionary(forKey: Keys.appRules) as? [String: String] ?? [:]
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

/// Snapshot of the settings `CloudLLMProcessor` needs, taken in one MainActor hop
/// (`AppSettings.cloudLLMSnapshot`) so provider, base URL, model, key, and vocabulary can never
/// observe a mid-update mix — e.g. a provider switch landing between separate `await` reads.
/// Captured by `AppCoordinator` at processor-selection time and passed into
/// `CloudLLMProcessor.process` — the processor itself never re-reads `AppSettings`/Keychain.
/// See PLAN.md step 4, Round 1 Codex finding 5; Amendment A1/A2.
struct CloudLLMSettingsSnapshot {
    let provider: LLMProviderKind
    let baseURL: String
    let model: String
    /// The active provider's scoped Keychain key, read as part of the same snapshot so routing
    /// decision (`AppCoordinator.isCloudLLMConfigured`) and the request always agree on whether
    /// a key is present. nil/empty both mean "no key".
    let key: String?
    let vocabulary: [String]
}

extension AppSettings {
    var cloudLLMSnapshot: CloudLLMSettingsSnapshot {
        CloudLLMSettingsSnapshot(
            provider: llmProvider,
            baseURL: cloudLLMBaseURL,
            model: cloudLLMModel,
            key: Keychain.get(account: Keychain.Account.cloudLLMKey(for: llmProvider)),
            vocabulary: vocabulary
        )
    }
}
