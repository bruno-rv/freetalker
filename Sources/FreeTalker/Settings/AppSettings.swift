import Foundation

extension Notification.Name {
    static let cloudLLMCredentialsDidChange = Notification.Name("CloudLLMCredentialsDidChange")
    static let scratchpadCloudCredentialsDidChange = cloudLLMCredentialsDidChange
}

enum STTEngineKind: String, CaseIterable, Codable {
    case whisperKit
    case cloud
}

enum LLMProviderKind: String, CaseIterable, Codable, Sendable {
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

    private let defaults: UserDefaults

    /// The push-to-talk hotkey: modifier chord and/or non-modifier key. Persisted as JSON;
    /// legacy single-modifier installs (pre-HotKeySpec `hotKeyDeviceMask`) are migrated in
    /// `init` so an existing assignment keeps working.
    @Published var hotKeySpec: HotKeySpec {
        didSet {
            if let data = try? JSONEncoder().encode(hotKeySpec) {
                defaults.set(data, forKey: Keys.hotKeySpec)
            }
            // A PTT change can invalidate a previously-valid Insert Last Dictation pair (now
            // colliding with it, or shadow-engaged before its own keyDown) even outside the
            // recorder's own pre-check in SettingsView — e.g. a hand-edited default, or any
            // future call site that assigns `hotKeySpec` directly. Re-validating here keeps the
            // two settings consistent no matter how `hotKeySpec` changes;
            // `insertLastDictationHotKeySpec`'s own `didSet` below handles dropping the now-stale
            // persisted key. See Round 1 Codex finding 10.
            if let insertLastDictationHotKeySpec, HotKeySpec.validInsertLastDictationSpec(insertLastDictationHotKeySpec, pttSpec: hotKeySpec) == nil {
                self.insertLastDictationHotKeySpec = nil
            }
            if let voiceEditHotKeySpec,
               HotKeySpec.validActionSpec(voiceEditHotKeySpec, pttSpec: hotKeySpec, otherActionSpec: insertLastDictationHotKeySpec) == nil {
                self.voiceEditHotKeySpec = nil
            }
        }
    }

    // ponytail: raw UserDefaults key stays "redoHotKeySpec" (see Keys.insertLastDictationHotKeySpec
    // below) so existing users' saved bindings survive the "Redo Last" → "Insert Last Dictation"
    // rename — only the Swift-facing name changed.
    @Published var insertLastDictationHotKeySpec: HotKeySpec? {
        didSet {
            // Re-validate against the current PTT spec on every assignment, not just the ones
            // coming from SettingsView's recorder (which already checks before assigning) — a
            // hand-edited default, or a direct assignment from any future call site, must never
            // let an invalid pair (modifier-only, side-normalized collision, or prefix-shadow vs.
            // PTT) persist. Invalid candidates silently drop to unbound (nil) rather than raising
            // a user prompt from here, which has no synchronous UI to surface one to. Reassigning
            // `self.insertLastDictationHotKeySpec` from inside this same observer does not
            // re-invoke it (same reasoning as `vocabularyText`/`handsFreeMaxMinutes` above), so
            // this falls straight through to the persistence branch below on the next (nil)
            // value. See Round 1 Codex finding 10.
            if let insertLastDictationHotKeySpec,
               HotKeySpec.validActionSpec(insertLastDictationHotKeySpec, pttSpec: hotKeySpec, otherActionSpec: voiceEditHotKeySpec) == nil {
                self.insertLastDictationHotKeySpec = nil
                defaults.removeObject(forKey: Keys.insertLastDictationHotKeySpec)
                return
            }
            if let insertLastDictationHotKeySpec, let data = try? JSONEncoder().encode(insertLastDictationHotKeySpec) {
                defaults.set(data, forKey: Keys.insertLastDictationHotKeySpec)
            } else {
                defaults.removeObject(forKey: Keys.insertLastDictationHotKeySpec)
            }
        }
    }

    @Published var voiceEditHotKeySpec: HotKeySpec? {
        didSet {
            if let voiceEditHotKeySpec,
               HotKeySpec.validActionSpec(voiceEditHotKeySpec, pttSpec: hotKeySpec, otherActionSpec: insertLastDictationHotKeySpec) == nil {
                self.voiceEditHotKeySpec = nil
                defaults.removeObject(forKey: Keys.voiceEditHotKeySpec)
                return
            }
            if let voiceEditHotKeySpec, let data = try? JSONEncoder().encode(voiceEditHotKeySpec) {
                defaults.set(data, forKey: Keys.voiceEditHotKeySpec)
            } else {
                defaults.removeObject(forKey: Keys.voiceEditHotKeySpec)
            }
        }
    }

    @Published var sttEngine: STTEngineKind {
        didSet { defaults.set(sttEngine.rawValue, forKey: Keys.sttEngine) }
    }
    /// Stripped to scheme + host + port + path at the setter level (see `strippedBaseURL`) so a
    /// credential typed into userinfo/query/fragment is never persisted, let alone exported. See
    /// PLAN.md F1.3.
    @Published var cloudSTTBaseURL: String {
        didSet {
            let stripped = Self.strippedBaseURL(cloudSTTBaseURL)
            guard stripped == cloudSTTBaseURL else {
                cloudSTTBaseURL = stripped
                defaults.set(stripped, forKey: Keys.cloudSTTBaseURL)
                return
            }
            defaults.set(cloudSTTBaseURL, forKey: Keys.cloudSTTBaseURL)
        }
    }
    @Published private(set) var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Keys.whisperModel) }
    }
    @Published var whisperModelChosen: Bool {
        didSet { defaults.set(whisperModelChosen, forKey: Keys.whisperModelChosen) }
    }

    func setWhisperModelFromUser(_ model: String) {
        whisperModel = SpeechModelCatalog.normalize(model)
        whisperModelChosen = true
    }

    func applyAutomaticWhisperModel(_ model: String) {
        whisperModel = SpeechModelCatalog.normalize(model)
    }

    @Published var livePreviewEnabled: Bool {
        didSet { defaults.set(livePreviewEnabled, forKey: Keys.livePreviewEnabled) }
    }

    @Published var noiseSuppressionEnabled: Bool {
        didSet { defaults.set(noiseSuppressionEnabled, forKey: Keys.noiseSuppressionEnabled) }
    }

    @Published var edgeLauncherEnabled: Bool {
        didSet { defaults.set(edgeLauncherEnabled, forKey: Keys.edgeLauncherEnabled) }
    }

    @Published var edgeLauncherEdge: LauncherEdge {
        didSet {
            defaults.set(edgeLauncherEdge.rawValue, forKey: Keys.edgeLauncherEdge)
            guard edgeLauncherEdge != oldValue else { return }
            resetLauncherPanelPosition()
        }
    }

    private var isNormalizingEdgeLauncherPosition = false

    @Published var edgeLauncherPosition: Double {
        didSet {
            guard !isNormalizingEdgeLauncherPosition else { return }
            let oldEffectiveValue = Self.clampNormalizedPosition(oldValue)
            let clamped = Self.clampNormalizedPosition(edgeLauncherPosition)
            if clamped != edgeLauncherPosition {
                isNormalizingEdgeLauncherPosition = true
                edgeLauncherPosition = clamped
                isNormalizingEdgeLauncherPosition = false
            }
            defaults.set(clamped, forKey: Keys.edgeLauncherPosition)
            guard clamped != oldEffectiveValue else { return }
            resetLauncherPanelPosition()
        }
    }

    @Published var launcherPanelPosition: NormalizedWindowPosition? {
        didSet {
            persistPanelPosition(launcherPanelPosition, key: Keys.launcherPanelPosition)
        }
    }

    @Published var recordingHUDPosition: NormalizedWindowPosition? {
        didSet {
            persistPanelPosition(recordingHUDPosition, key: Keys.recordingHUDPosition)
        }
    }

    @Published var transientHUDPosition: NormalizedWindowPosition? {
        didSet {
            persistPanelPosition(transientHUDPosition, key: Keys.transientHUDPosition)
        }
    }

    func resetLauncherPanelPosition() {
        launcherPanelPosition = nil
    }

    func resetRecordingHUDPosition() {
        recordingHUDPosition = nil
    }

    func resetTransientHUDPosition() {
        transientHUDPosition = nil
    }

    private func persistPanelPosition(_ position: NormalizedWindowPosition?, key: String) {
        guard let position else {
            defaults.removeObject(forKey: key)
            return
        }
        guard position.isValid, let data = try? JSONEncoder().encode(position) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func panelPosition(from defaults: UserDefaults, key: String) -> NormalizedWindowPosition? {
        guard let data = defaults.data(forKey: key),
              let position = try? JSONDecoder().decode(NormalizedWindowPosition.self, from: data),
              position.isValid else {
            return nil
        }
        return position
    }

    nonisolated static func clampNormalizedPosition(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    @Published var llmProvider: LLMProviderKind {
        didSet {
            defaults.set(llmProvider.rawValue, forKey: Keys.llmProvider)
            let resolved = Self.resolveProviderDefaults(provider: llmProvider, baseURL: cloudLLMBaseURL, model: cloudLLMModel)
            if resolved.baseURL != cloudLLMBaseURL { cloudLLMBaseURL = resolved.baseURL }
            if resolved.model != cloudLLMModel { cloudLLMModel = resolved.model }
        }
    }
    /// Stripped to scheme + host + port + path at the setter level — see `cloudSTTBaseURL` above
    /// and `strippedBaseURL`.
    @Published var cloudLLMBaseURL: String {
        didSet {
            let stripped = Self.strippedBaseURL(cloudLLMBaseURL)
            guard stripped == cloudLLMBaseURL else {
                cloudLLMBaseURL = stripped
                defaults.set(stripped, forKey: Keys.cloudLLMBaseURL)
                return
            }
            defaults.set(cloudLLMBaseURL, forKey: Keys.cloudLLMBaseURL)
        }
    }
    @Published var cloudLLMModel: String {
        didSet { defaults.set(cloudLLMModel, forKey: Keys.cloudLLMModel) }
    }

    @Published var activeTemplateID: String {
        didSet { defaults.set(activeTemplateID, forKey: Keys.activeTemplateID) }
    }

    @Published var recoveryRetention: RecoveryRetention {
        didSet { defaults.set(recoveryRetention.rawValue, forKey: Keys.recoveryRetention) }
    }

    @Published var mediaImportRetention: MediaImportRetention {
        didSet { defaults.set(mediaImportRetention.rawValue, forKey: Keys.mediaImportRetention) }
    }

    @Published var localContextScope: LocalContextScope {
        didSet { defaults.set(localContextScope.rawValue, forKey: Keys.localContextScope) }
    }

    @Published var automaticStyleEnabled: Bool {
        didSet { defaults.set(automaticStyleEnabled, forKey: Keys.automaticStyleEnabled) }
    }

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

    nonisolated static func clampHandsFreeMaxMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 1), 60)
    }

    @Published var appRules: [String: String] {
        didSet { defaults.set(appRules, forKey: Keys.appRules) }
    }

    @Published var languagePin: String {
        didSet {
            let normalized = Self.normalizeLanguagePin(languagePin, allowed: dictationLanguages)
            guard normalized == languagePin else {
                languagePin = normalized
                defaults.set(normalized, forKey: Keys.languagePin)
                return
            }
            defaults.set(languagePin, forKey: Keys.languagePin)
        }
    }

    @Published var defaultOutputLanguage: OutputLanguage {
        didSet { defaults.set(defaultOutputLanguage.rawValue, forKey: Keys.defaultOutputLanguage) }
    }

    @Published var appLanguageRules: [String: String] {
        didSet {
            let sanitized = Self.sanitizedLanguageRules(appLanguageRules, allowed: dictationLanguages)
            guard sanitized == appLanguageRules else {
                appLanguageRules = sanitized
                defaults.set(sanitized, forKey: Keys.appLanguageRules)
                return
            }
            defaults.set(appLanguageRules, forKey: Keys.appLanguageRules)
        }
    }

    /// The user-configured Dictation Language Set (F5): the subset of `DictationLanguage`'s
    /// curated 8 that constrains on-device (WhisperKit-only, see `WhisperKitEngine`) spoken-
    /// language auto-detection. Cloud STT is unchanged — it only ever takes a single
    /// `forcedLanguage`. See PLAN.md F5 and `CONTEXT.md`'s "Dictation Language Set" glossary
    /// entry.
    @Published var dictationLanguages: [String] {
        didSet {
            let normalized = Self.normalizeDictationLanguages(dictationLanguages)
            guard normalized == dictationLanguages else {
                dictationLanguages = normalized
                defaults.set(normalized, forKey: Keys.dictationLanguages)
                coerceLanguageDependents()
                return
            }
            defaults.set(dictationLanguages, forKey: Keys.dictationLanguages)
            coerceLanguageDependents()
        }
    }

    /// Coercion at set-change time (PLAN.md F5.4, "not lazily"): re-validates `languagePin`/
    /// `appLanguageRules` against the just-changed `dictationLanguages` set the moment it
    /// changes, rather than leaving a now-invalid pin/rule sitting in `UserDefaults` until the
    /// next unrelated read. Re-assigns through the public setters (not private field writes) so
    /// each property's own didSet/persistence logic runs unchanged — same idiom as
    /// `hotKeySpec`'s sibling-invalidation above. Active one-shot language coercion is
    /// AppCoordinator-owned state (not part of `AppSettings`) and is handled there via a
    /// `$dictationLanguages` subscription — see `AppCoordinator.handleDictationLanguagesChange`.
    private func coerceLanguageDependents() {
        let normalizedPin = Self.normalizeLanguagePin(languagePin, allowed: dictationLanguages)
        if normalizedPin != languagePin { languagePin = normalizedPin }
        let sanitizedRules = Self.sanitizedLanguageRules(appLanguageRules, allowed: dictationLanguages)
        if sanitizedRules != appLanguageRules { appLanguageRules = sanitizedRules }
    }

    /// Validates a candidate spoken-language code (an app-rule value or a one-shot selection)
    /// against `allowed` — the configured Dictation Language Set (or, at Backup Bundle decode
    /// time before the restored set is known, the full curated 8; see
    /// `SettingsPatchDecoding`). An unknown/garbage/removed code is rejected, not silently
    /// coerced.
    nonisolated static func normalizeLanguageCode(_ raw: String, allowed: [String]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowed.contains(trimmed) ? trimmed : nil
    }

    /// Normalizes the `languagePin` property's own value, whose valid domain also includes
    /// "auto" (unlike a rule/one-shot candidate) — any other value falls back to "auto".
    nonisolated static func normalizeLanguagePin(_ raw: String, allowed: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "auto" || allowed.contains(trimmed) ? trimmed : "auto"
    }

    /// Drops any `appLanguageRules` entry whose value doesn't normalize to a code in `allowed` —
    /// an unknown/garbage/removed code is dropped, not silently coerced. Keys (bundle ids) are
    /// passed through unchanged. This is the "appLanguageRules entries pointing at a removed
    /// language are DELETED" half of PLAN.md F5.4's set-change coercion.
    nonisolated static func sanitizedLanguageRules(_ raw: [String: String], allowed: [String]) -> [String: String] {
        raw.compactMapValues { normalizeLanguageCode($0, allowed: allowed) }
    }

    /// Default Dictation Language Set (PLAN.md F5.1) — also the normalizer's fallback when every
    /// candidate is invalid/duplicate/unknown (never an empty set).
    nonisolated static let defaultDictationLanguages = ["en", "pt"]

    /// Subset of `DictationLanguage`'s curated 8, deduped (first occurrence wins, order
    /// preserved), minimum one — an empty or all-invalid input falls back to
    /// `defaultDictationLanguages` rather than persisting an empty set (PLAN.md F5.1).
    nonisolated static func normalizeDictationLanguages(_ raw: [String]) -> [String] {
        let curated = Set(DictationLanguage.allCases.map(\.rawValue))
        var seen = Set<String>()
        var kept: [String] = []
        for code in raw {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard curated.contains(trimmed), seen.insert(trimmed).inserted else { continue }
            kept.append(trimmed)
        }
        return kept.isEmpty ? defaultDictationLanguages : kept
    }

    struct AppRuleRow: Identifiable, Equatable {
        let bundleID: String
        let templateID: String?
        let language: String?
        var id: String { bundleID }
    }

    nonisolated static func unifiedAppRuleRows(appRules: [String: String], appLanguageRules: [String: String]) -> [AppRuleRow] {
        let allBundleIDs = Set(appRules.keys).union(appLanguageRules.keys)
        return allBundleIDs.sorted().map { bundleID in
            AppRuleRow(bundleID: bundleID, templateID: appRules[bundleID], language: appLanguageRules[bundleID])
        }
    }

    nonisolated static func removingAppRule(bundleID: String, appRules: [String: String], appLanguageRules: [String: String]) -> (appRules: [String: String], appLanguageRules: [String: String]) {
        var rules = appRules
        var languageRules = appLanguageRules
        rules.removeValue(forKey: bundleID)
        languageRules.removeValue(forKey: bundleID)
        return (rules, languageRules)
    }

    /// Pure "Add" for a unified App Rules row: REPLACES the bundle id's whole row rather than
    /// merging into whatever halves already exist — a nil half clears that dict's entry instead
    /// of leaving a stale one active. E.g. re-adding Slack as language-only EN must drop its old
    /// template override, not just leave it untouched alongside the new language. See Codex
    /// finding on SettingsView.swift:332.
    nonisolated static func applyingAppRule(bundleID: String, templateID: String?, language: String?, appRules: [String: String], appLanguageRules: [String: String]) -> (appRules: [String: String], appLanguageRules: [String: String]) {
        var rules = appRules
        var languageRules = appLanguageRules
        if let templateID {
            rules[bundleID] = templateID
        } else {
            rules.removeValue(forKey: bundleID)
        }
        if let language {
            languageRules[bundleID] = language
        } else {
            languageRules.removeValue(forKey: bundleID)
        }
        return (rules, languageRules)
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

    /// Strips a base-URL string to scheme + host [:port] + path — drops userinfo, query, and
    /// fragment, the only places a credential can ride along in a URL string. Applied at the
    /// `cloudSTTBaseURL`/`cloudLLMBaseURL` setter level (not just at export time) so stored state
    /// is always already clean — see PLAN.md F1.3. Idempotent: re-stripping an already-stripped
    /// URL returns it unchanged. Unparseable input (no scheme+host, e.g. a partial edit) is
    /// trimmed but passed through rather than discarded, so an in-progress edit isn't wiped.
    nonisolated static func strippedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme, let host = components.host else {
            return trimmed
        }
        var stripped = URLComponents()
        stripped.scheme = scheme
        stripped.host = host
        stripped.port = components.port
        stripped.path = components.path
        return stripped.string ?? trimmed
    }

    nonisolated static let knownProviderDefaults: [LLMProviderKind: LLMProviderDefault] = [
        .anthropic: LLMProviderDefault(baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-4-5"),
        .ollama: LLMProviderDefault(baseURL: "https://ollama.com/v1", model: "gpt-oss:120b"),
        .openAICompatible: LLMProviderDefault(baseURL: nil, model: nil)
    ]

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

    // Internal (not private) so `BackupBundle.swift` can key its JSON export/decode against the
    // exact same UserDefaults key strings the setters/exporters use. See `exportableKeys` above.
    enum Keys {
        static let hotKeySpec = "hotKeySpec"
        /// Raw value intentionally kept as the old "redoHotKeySpec" string (pre-rename) — this
        /// is UserDefaults' persisted key, so changing it would silently drop every user's saved
        /// Insert Last Dictation binding. Only the Swift-facing name changed.
        static let insertLastDictationHotKeySpec = "redoHotKeySpec"
        static let voiceEditHotKeySpec = "voiceEditHotKeySpec"
        /// Legacy (read-only, for migration): single-modifier NX device mask bit.
        static let legacyHotKeyDeviceMask = "hotKeyDeviceMask"
        static let sttEngine = "sttEngine"
        static let cloudSTTBaseURL = "cloudSTTBaseURL"
        static let whisperModel = "whisperModel"
        static let whisperModelChosen = "whisperModelChosen"
        static let livePreviewEnabled = "livePreviewEnabled"
        static let noiseSuppressionEnabled = "noiseSuppressionEnabled"
        static let edgeLauncherEnabled = "edgeLauncherEnabled"
        static let edgeLauncherEdge = "edgeLauncherEdge"
        static let edgeLauncherPosition = "edgeLauncherPosition"
        static let launcherPanelPosition = "launcherPanelPosition"
        static let recordingHUDPosition = "recordingHUDPosition"
        static let transientHUDPosition = "transientHUDPosition"
        /// Legacy (read-only, for migration): shared HUD position.
        static let hudPosition = "hudPosition"
        static let llmProvider = "llmProvider"
        static let cloudLLMBaseURL = "cloudLLMBaseURL"
        static let cloudLLMModel = "cloudLLMModel"
        static let activeTemplateID = "activeTemplateID"
        static let recoveryRetention = "recoveryRetention"
        static let mediaImportRetention = "mediaImportRetention"
        static let localContextScope = "localContextScope"
        static let automaticStyleEnabled = "automaticStyleEnabled"
        static let handsFreeMaxMinutes = "handsFreeMaxMinutes"
        static let appRules = "appRules"
        static let languagePin = "languagePin"
        static let defaultOutputLanguage = "defaultOutputLanguage"
        static let appLanguageRules = "appLanguageRules"
        static let dictationLanguages = "dictationLanguages"
        static let microphoneDeviceUID = "microphoneDeviceUID"
        static let vocabularyText = "vocabularyText"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.hotKeySpec),
           let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) {
            hotKeySpec = spec
        } else if let legacyMask = defaults.object(forKey: Keys.legacyHotKeyDeviceMask) as? Int64, legacyMask != 0 {
            // Migrate a pre-HotKeySpec single-modifier assignment (e.g. "Left ⌃").
            hotKeySpec = HotKeySpec(modifiers: UInt64(bitPattern: legacyMask), keyCode: nil)
        } else {
            hotKeySpec = .default
        }
        if let data = defaults.data(forKey: Keys.insertLastDictationHotKeySpec) {
            insertLastDictationHotKeySpec = try? JSONDecoder().decode(HotKeySpec.self, from: data)
        } else {
            insertLastDictationHotKeySpec = nil
        }
        if let data = defaults.data(forKey: Keys.voiceEditHotKeySpec) {
            voiceEditHotKeySpec = try? JSONDecoder().decode(HotKeySpec.self, from: data)
        } else {
            voiceEditHotKeySpec = nil
        }
        sttEngine = STTEngineKind(rawValue: defaults.string(forKey: Keys.sttEngine) ?? "") ?? .whisperKit
        // One-time load normalization: a value stored before setter-level stripping existed (or
        // hand-edited) may still carry userinfo/query/fragment credentials — strip and persist
        // back so on-disk state converges to the same invariant the setter now enforces. See
        // PLAN.md F1.3.
        let storedCloudSTTBaseURL = defaults.string(forKey: Keys.cloudSTTBaseURL) ?? "https://api.openai.com/v1"
        let strippedCloudSTTBaseURL = Self.strippedBaseURL(storedCloudSTTBaseURL)
        cloudSTTBaseURL = strippedCloudSTTBaseURL
        if strippedCloudSTTBaseURL != storedCloudSTTBaseURL {
            defaults.set(strippedCloudSTTBaseURL, forKey: Keys.cloudSTTBaseURL)
        }
        let storedWhisperModel = defaults.string(forKey: Keys.whisperModel) ?? SpeechModelCatalog.defaultID
        let normalizedWhisperModel = SpeechModelCatalog.normalize(storedWhisperModel)
        whisperModel = normalizedWhisperModel
        whisperModelChosen = defaults.object(forKey: Keys.whisperModelChosen) as? Bool ?? false
        if normalizedWhisperModel != storedWhisperModel {
            defaults.set(normalizedWhisperModel, forKey: Keys.whisperModel)
        }
        // Default ON — `.object(forKey:)` (not `.bool(forKey:)`) so an unset key is distinguished
        // from an explicit `false`, which `.bool(forKey:)` can't do (it returns false for both).
        livePreviewEnabled = defaults.object(forKey: Keys.livePreviewEnabled) as? Bool ?? true
        noiseSuppressionEnabled = defaults.object(forKey: Keys.noiseSuppressionEnabled) as? Bool ?? true
        edgeLauncherEnabled = defaults.object(forKey: Keys.edgeLauncherEnabled) as? Bool ?? false
        edgeLauncherEdge = LauncherEdge(rawValue: defaults.string(forKey: Keys.edgeLauncherEdge) ?? "") ?? .right
        let storedEdgeLauncherPosition = defaults.object(forKey: Keys.edgeLauncherPosition) as? Double ?? 0.5
        edgeLauncherPosition = Self.clampNormalizedPosition(storedEdgeLauncherPosition)
        launcherPanelPosition = Self.panelPosition(from: defaults, key: Keys.launcherPanelPosition)
        recordingHUDPosition = Self.panelPosition(from: defaults, key: Keys.recordingHUDPosition)
        let savedTransientHUDPosition = Self.panelPosition(from: defaults, key: Keys.transientHUDPosition)
        let legacyHUDPosition = Self.panelPosition(from: defaults, key: Keys.hudPosition)
        transientHUDPosition = savedTransientHUDPosition ?? legacyHUDPosition
        if savedTransientHUDPosition == nil, let legacyHUDPosition {
            if let data = try? JSONEncoder().encode(legacyHUDPosition) {
                defaults.set(data, forKey: Keys.transientHUDPosition)
            }
        }
        // Loaded into locals first, not `self.llmProvider`/`self.cloudLLMBaseURL`/
        // `self.cloudLLMModel` directly: `self` can't be read (even its own not-yet-assigned
        // stored properties) until every stored property is initialized, and
        // `resolveProviderDefaults` needs all three together. No hardcoded base URL/model
        // fallback here — `resolveProviderDefaults` is the single source of truth for provider
        // defaults (an empty value resolves to the current provider's known default, if any).
        // See Round 1 Codex findings 2/4, Round 2 Codex finding 2 (direct init assignment
        // doesn't trigger `llmProvider`'s didSet, so this resolution must also run here, once).
        let loadedProvider = LLMProviderKind(rawValue: defaults.string(forKey: Keys.llmProvider) ?? "") ?? .anthropic
        // `storedCloudLLMBaseURL` (not the stripped value) is the write-back comparison target
        // below, so a credential stripped here by the one-time load normalization (same
        // reasoning as cloudSTTBaseURL above) is detected and persisted even when
        // `resolveProviderDefaults` itself leaves the (already-stripped) value unchanged.
        let storedCloudLLMBaseURL = defaults.string(forKey: Keys.cloudLLMBaseURL) ?? ""
        let strippedCloudLLMBaseURL = Self.strippedBaseURL(storedCloudLLMBaseURL)
        let rawCloudLLMModel = defaults.string(forKey: Keys.cloudLLMModel) ?? ""
        let resolvedProviderDefaults = Self.resolveProviderDefaults(provider: loadedProvider, baseURL: strippedCloudLLMBaseURL, model: rawCloudLLMModel)
        llmProvider = loadedProvider
        cloudLLMBaseURL = resolvedProviderDefaults.baseURL
        cloudLLMModel = resolvedProviderDefaults.model
        if resolvedProviderDefaults.baseURL != storedCloudLLMBaseURL {
            defaults.set(resolvedProviderDefaults.baseURL, forKey: Keys.cloudLLMBaseURL)
        }
        if resolvedProviderDefaults.model != rawCloudLLMModel {
            defaults.set(resolvedProviderDefaults.model, forKey: Keys.cloudLLMModel)
        }
        activeTemplateID = defaults.string(forKey: Keys.activeTemplateID) ?? Template.defaultID
        recoveryRetention = RecoveryRetention(rawValue: defaults.object(forKey: Keys.recoveryRetention) as? Int ?? 7) ?? .sevenDays
        mediaImportRetention = MediaImportRetention(rawValue: defaults.object(forKey: Keys.mediaImportRetention) as? Int ?? 7) ?? .default
        let storedLocalContextScope = defaults.string(forKey: Keys.localContextScope)
        localContextScope = storedLocalContextScope.flatMap(LocalContextScope.init(rawValue:)) ?? .off
        automaticStyleEnabled = defaults.bool(forKey: Keys.automaticStyleEnabled)
        if let storedLocalContextScope, LocalContextScope(rawValue: storedLocalContextScope) == nil {
            defaults.set(LocalContextScope.off.rawValue, forKey: Keys.localContextScope)
        }
        let storedHandsFreeMaxMinutes = defaults.object(forKey: Keys.handsFreeMaxMinutes) as? Int ?? 5
        handsFreeMaxMinutes = Self.clampHandsFreeMaxMinutes(storedHandsFreeMaxMinutes)
        appRules = defaults.dictionary(forKey: Keys.appRules) as? [String: String] ?? [:]
        // Loaded into a local first (same reasoning as `resolvedProviderDefaults` above): `self`
        // can't be read until every stored property is initialized, so `languagePin`/
        // `appLanguageRules`' own load-time normalization below — which must validate against
        // the just-loaded Dictation Language Set, not the hardcoded en/pt pair — uses this local
        // rather than `self.dictationLanguages`. See PLAN.md F5.1/F5.4.
        let storedDictationLanguages = defaults.array(forKey: Keys.dictationLanguages) as? [String] ?? Self.defaultDictationLanguages
        let normalizedDictationLanguages = Self.normalizeDictationLanguages(storedDictationLanguages)
        dictationLanguages = normalizedDictationLanguages
        if normalizedDictationLanguages != storedDictationLanguages {
            defaults.set(normalizedDictationLanguages, forKey: Keys.dictationLanguages)
        }
        let storedLanguagePin = defaults.string(forKey: Keys.languagePin) ?? "auto"
        let normalizedLanguagePin = Self.normalizeLanguagePin(storedLanguagePin, allowed: normalizedDictationLanguages)
        languagePin = normalizedLanguagePin
        if normalizedLanguagePin != storedLanguagePin {
            defaults.set(normalizedLanguagePin, forKey: Keys.languagePin)
        }
        let storedDefaultOutputLanguage = defaults.string(forKey: Keys.defaultOutputLanguage)
        let normalizedDefaultOutputLanguage = OutputLanguage.persisted(rawValue: storedDefaultOutputLanguage)
        defaultOutputLanguage = normalizedDefaultOutputLanguage
        if storedDefaultOutputLanguage != normalizedDefaultOutputLanguage.rawValue {
            defaults.set(normalizedDefaultOutputLanguage.rawValue, forKey: Keys.defaultOutputLanguage)
        }
        let storedLanguageRules = defaults.dictionary(forKey: Keys.appLanguageRules) as? [String: String] ?? [:]
        let sanitizedLanguageRulesAtLoad = Self.sanitizedLanguageRules(storedLanguageRules, allowed: normalizedDictationLanguages)
        appLanguageRules = sanitizedLanguageRulesAtLoad
        if sanitizedLanguageRulesAtLoad != storedLanguageRules {
            defaults.set(sanitizedLanguageRulesAtLoad, forKey: Keys.appLanguageRules)
        }
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
        // All stored properties are initialized past this point, so `self`/`hotKeySpec` can be
        // read: a persisted Insert Last Dictation pair that's since become invalid — hand-edited
        // UserDefaults, or `hotKeySpec` migrated from a legacy value above in a way that now
        // collides/shadows it — must be re-validated here, since a direct init assignment (like
        // the `insertLastDictationHotKeySpec =` above) doesn't trigger its own `didSet` (same
        // reasoning as `vocabularyText`'s clamp above). See Round 1 Codex finding 10.
        if let insertLastDictationHotKeySpec,
           HotKeySpec.validActionSpec(insertLastDictationHotKeySpec, pttSpec: hotKeySpec, otherActionSpec: voiceEditHotKeySpec) == nil {
            self.insertLastDictationHotKeySpec = nil
            defaults.removeObject(forKey: Keys.insertLastDictationHotKeySpec)
        }
        if let voiceEditHotKeySpec,
           HotKeySpec.validActionSpec(voiceEditHotKeySpec, pttSpec: hotKeySpec, otherActionSpec: insertLastDictationHotKeySpec) == nil {
            self.voiceEditHotKeySpec = nil
            defaults.removeObject(forKey: Keys.voiceEditHotKeySpec)
        }
    }
}

struct CloudLLMSettingsSnapshot: Equatable, Sendable {
    let provider: LLMProviderKind
    let baseURL: String
    let model: String
    /// The active provider's scoped Keychain key, read as part of the same snapshot so routing
    /// decision (`AppCoordinator.isCloudLLMConfigured`) and the request always agree on whether
    /// a key is present. nil/empty both mean "no key".
    let key: String?
    let vocabulary: [String]

    var eligibility: CloudLLMEligibility {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedModel.isEmpty,
            let components = URLComponents(string: trimmedBaseURL),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host?.lowercased(),
            !host.isEmpty,
            Self.hasValidPortSyntax(in: trimmedBaseURL, components: components)
        else {
            return .invalidConfiguration
        }

        let trimmedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedKey.isEmpty {
            return .eligible(apiKey: trimmedKey)
        }

        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        if provider == .openAICompatible, scheme == "http", loopbackHosts.contains(normalizedHost) {
            return .eligible(apiKey: nil)
        }
        return .missingAPIKey
    }

    private static func hasValidPortSyntax(in url: String, components: URLComponents) -> Bool {
        guard let schemeEnd = url.range(of: "://") else { return false }
        let remainder = url[schemeEnd.upperBound...]
        let authorityEnd = remainder.firstIndex { "/?#".contains($0) } ?? remainder.endIndex
        let authority = remainder[..<authorityEnd]
        guard !authority.hasSuffix(":") else { return false }
        guard let port = components.port else { return true }
        return (1...65_535).contains(port)
    }
}

enum CloudLLMEligibility: Equatable, Sendable {
    case eligible(apiKey: String?)
    case invalidConfiguration
    case missingAPIKey

    var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
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

extension AppSettings {
    /// Every `Keys` entry that's safe and meaningful to export, excluding `legacyHotKeyDeviceMask`
    /// and `hudPosition` — both read-only migration keys that current code only ever reads, never
    /// writes. Never includes an API key: those live only in the Keychain (see Keychain.swift) and
    /// have no `UserDefaults` key at all.
    ///
    /// Internal (not private) so `BackupBundle.swift` can decode/apply against the same key set
    /// the exporters emit. `historyPanelHotKeySpec` and `dictationLanguages` (F3/F5) are not yet
    /// implemented — adding either is a one-line append here plus a matching `Keys.*` entry,
    /// `exportableSettingsSnapshot()` case, and `SettingsPatch` field/decode/apply case.
    static let exportableKeys: [String] = [
        Keys.hotKeySpec,
        Keys.insertLastDictationHotKeySpec,
        Keys.voiceEditHotKeySpec,
        Keys.sttEngine,
        Keys.cloudSTTBaseURL,
        Keys.whisperModel,
        Keys.whisperModelChosen,
        Keys.livePreviewEnabled,
        Keys.noiseSuppressionEnabled,
        Keys.edgeLauncherEnabled,
        Keys.edgeLauncherEdge,
        Keys.edgeLauncherPosition,
        Keys.launcherPanelPosition,
        Keys.recordingHUDPosition,
        Keys.transientHUDPosition,
        Keys.llmProvider,
        Keys.cloudLLMBaseURL,
        Keys.cloudLLMModel,
        Keys.activeTemplateID,
        Keys.recoveryRetention,
        Keys.mediaImportRetention,
        Keys.localContextScope,
        Keys.automaticStyleEnabled,
        Keys.handsFreeMaxMinutes,
        Keys.appRules,
        Keys.languagePin,
        Keys.defaultOutputLanguage,
        Keys.appLanguageRules,
        Keys.dictationLanguages,
        Keys.microphoneDeviceUID,
        Keys.vocabularyText
    ]

    /// Exports every non-secret setting to a human-readable JSON file. Reads only the
    /// `UserDefaults` keys above — never the Keychain — so the API key can never end up in the
    /// output. Values persisted as JSON-encoded `Data` (hotkeys, HUD/panel positions) are decoded
    /// and embedded as nested JSON rather than base64 blobs; everything else embeds directly.
    func exportSettingsJSON() throws -> Data {
        var settings: [String: Any] = [:]
        for key in Self.exportableKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let data = value as? Data {
                if let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    settings[key] = decoded
                }
                // Defensive: an undecodable blob is skipped rather than crashing the export.
            } else if JSONSerialization.isValidJSONObject([value]) {
                settings[key] = value
            }
        }
        let payload: [String: Any] = [
            "formatVersion": 1,
            "app": "FreeTalker",
            "settings": settings
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    /// Complete v2 snapshot: every `exportableKeys` entry, always present, at its current
    /// normalized (live-property) value — nil-valued optionals encode as `NSNull` so the key
    /// stays present rather than being omitted. Unlike `exportSettingsJSON()`'s v1 "only keys
    /// UserDefaults happens to have an entry for" semantics, this makes "restore = overwrite"
    /// well-defined: every key's *documented default* is already what the live property holds
    /// when UserDefaults has no stored entry (see `init`), so reading the properties directly —
    /// not `defaults.object(forKey:)` — is what gives completeness for free. See PLAN.md F1.2.
    /// The JSON shape per key matches `exportSettingsJSON()`'s (hotkey/position structs embedded
    /// as nested JSON, not base64), so `BackupBundle.swift` decodes both formats with one reader.
    func exportableSettingsSnapshot() -> [String: Any] {
        func jsonValue<T: Encodable>(_ value: T) -> Any {
            guard let data = try? JSONEncoder().encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return NSNull()
            }
            return object
        }
        var out: [String: Any] = [:]
        out[Keys.hotKeySpec] = jsonValue(hotKeySpec)
        out[Keys.insertLastDictationHotKeySpec] = insertLastDictationHotKeySpec.map(jsonValue) ?? NSNull()
        out[Keys.voiceEditHotKeySpec] = voiceEditHotKeySpec.map(jsonValue) ?? NSNull()
        out[Keys.sttEngine] = sttEngine.rawValue
        out[Keys.cloudSTTBaseURL] = cloudSTTBaseURL
        out[Keys.whisperModel] = whisperModel
        out[Keys.whisperModelChosen] = whisperModelChosen
        out[Keys.livePreviewEnabled] = livePreviewEnabled
        out[Keys.noiseSuppressionEnabled] = noiseSuppressionEnabled
        out[Keys.edgeLauncherEnabled] = edgeLauncherEnabled
        out[Keys.edgeLauncherEdge] = edgeLauncherEdge.rawValue
        out[Keys.edgeLauncherPosition] = edgeLauncherPosition
        out[Keys.launcherPanelPosition] = launcherPanelPosition.map(jsonValue) ?? NSNull()
        out[Keys.recordingHUDPosition] = recordingHUDPosition.map(jsonValue) ?? NSNull()
        out[Keys.transientHUDPosition] = transientHUDPosition.map(jsonValue) ?? NSNull()
        out[Keys.llmProvider] = llmProvider.rawValue
        out[Keys.cloudLLMBaseURL] = cloudLLMBaseURL
        out[Keys.cloudLLMModel] = cloudLLMModel
        out[Keys.activeTemplateID] = activeTemplateID
        out[Keys.recoveryRetention] = recoveryRetention.rawValue
        out[Keys.mediaImportRetention] = mediaImportRetention.rawValue
        out[Keys.localContextScope] = localContextScope.rawValue
        out[Keys.automaticStyleEnabled] = automaticStyleEnabled
        out[Keys.handsFreeMaxMinutes] = handsFreeMaxMinutes
        out[Keys.appRules] = appRules
        out[Keys.languagePin] = languagePin
        out[Keys.defaultOutputLanguage] = defaultOutputLanguage.rawValue
        out[Keys.appLanguageRules] = appLanguageRules
        out[Keys.dictationLanguages] = dictationLanguages
        out[Keys.microphoneDeviceUID] = microphoneDeviceUID ?? NSNull()
        out[Keys.vocabularyText] = vocabularyText
        return out
    }
}
