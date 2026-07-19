import Foundation

/// Errors surfaced by Backup Bundle export/restore (Settings → Storage → Back Up…/Restore…).
/// Restore is validate-all-then-apply: every case below except `stageFailed` is raised BEFORE
/// any write, so an invalid bundle never partially applies. See PLAN.md F1.4.
enum BackupBundleError: LocalizedError, Equatable {
    case fileTooLarge(maxBytes: Int)
    case invalidEnvelope
    case notFreeTalkerBundle
    case unsupportedFormatVersion(Int)
    case invalidSettingsValue(key: String)
    case invalidSettingsSection
    case invalidTemplatesSection
    case invalidSnippetsSection
    case tooManyTemplates(max: Int)
    case tooManySnippets(max: Int)
    case stringTooLong(field: String, maxBytes: Int)
    case tooManyRuleEntries(field: String, max: Int)
    case invalidVocabDecisionsSection
    case tooManyVocabDecisions(max: Int)
    /// A later stage (snippets/settings) failed after an earlier one (templates/snippets)
    /// already committed. `partial` reports exactly what was applied — no silent partial
    /// restore, no fake atomicity claim across UserDefaults + JSON + SQLite. See PLAN.md F1.5.
    case stageFailed(stage: String, partial: BackupBundleImportResult, underlying: String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let maxBytes):
            return "This backup file is larger than the \(maxBytes / (1024 * 1024)) MB limit."
        case .invalidEnvelope:
            return "This file isn't a valid FreeTalker backup."
        case .notFreeTalkerBundle:
            return "This file isn't a FreeTalker backup."
        case .unsupportedFormatVersion(let version):
            return "This backup uses a format (\(version)) this version of FreeTalker doesn't support."
        case .invalidSettingsValue(let key):
            return "The backup's \"\(key)\" setting is invalid."
        case .invalidSettingsSection:
            return "The backup's settings section is missing or invalid."
        case .invalidTemplatesSection:
            return "The backup's templates section is invalid."
        case .invalidSnippetsSection:
            return "The backup's snippets section is invalid."
        case .tooManyTemplates(let max):
            return "This backup has more than \(max) templates."
        case .tooManySnippets(let max):
            return "This backup has more than \(max) snippets."
        case .stringTooLong(let field, let maxBytes):
            return "A \(field) in this backup exceeds the \(maxBytes)-byte limit."
        case .tooManyRuleEntries(let field, let max):
            return "This backup's \(field) has more than \(max) entries."
        case .invalidVocabDecisionsSection:
            return "The backup's vocabulary decisions section is invalid."
        case .tooManyVocabDecisions(let max):
            return "This backup has more than \(max) vocabulary decisions."
        case .stageFailed(let stage, let partial, let underlying):
            return "Restore stopped while applying \(stage): \(underlying). Already applied: \(partial.templatesImported) templates, \(partial.snippetsImported) snippets."
        }
    }
}

/// Counts + partial-failure honesty for a completed or failed restore. See PLAN.md F1.5/F1.8.
struct BackupBundleImportResult: Equatable, Sendable {
    var templatesImported = 0
    var templatesSkipped = 0
    var snippetsImported = 0
    var snippetsSkipped = 0
    /// Approve/dismiss decisions applied because the incoming `decidedAt` was strictly newer than
    /// whatever was already stored (or the term was brand new) — see `VocabStore.mergeDecisions`.
    /// See PLAN.md PR B, item 2c.
    var vocabDecisionsImported = 0
    /// Incoming decisions skipped because the existing stored decision was already newer (or
    /// equal) — the existing one wins, never a silent overwrite. See PLAN.md PR B, item 2c.
    var vocabDecisionsSkipped = 0
    var settingsApplied = false
}

/// Input bounds enforced before/at decode (PLAN.md F1.4) — new, since the repo has no
/// template/snippet field clamps today.
enum BackupBundleBounds {
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxTemplates = 500
    static let maxSnippets = 1_000
    static let maxTemplateNameBytes = 500
    static let maxTemplatePromptBytes = 50_000
    static let maxSnippetTriggerBytes = 500
    static let maxSnippetExpansionBytes = 50_000
    static let maxRuleEntries = 200
    static let maxRuleKeyBytes = 500
    static let maxRuleValueBytes = 500
    /// Generous relative to how many terms could ever be approved (each one already passed the
    /// fit gate against a ~224-token budget) — bounds decode, not a realistic usage ceiling.
    static let maxVocabDecisions = 2_000
}

/// Whether an exportable key was present in the decoded bundle at all, distinct from the typed
/// value itself being `nil` (an optional AppSettings property explicitly unbound). `.absent`
/// drives v1's "leave untouched" vs. v2's "reset to default" apply semantics — see
/// `AppSettings.applySettingsPatch`.
enum PatchField<T> {
    case absent
    case present(T)
}

/// Typed, key-by-key decode of a Backup Bundle's `settings` section — one field per
/// `AppSettings.exportableKeys` entry. See PLAN.md F1.9.
struct SettingsPatch {
    var hotKeySpec: PatchField<HotKeySpec> = .absent
    var insertLastDictationHotKeySpec: PatchField<HotKeySpec?> = .absent
    var voiceEditHotKeySpec: PatchField<HotKeySpec?> = .absent
    var historyPanelHotKeySpec: PatchField<HotKeySpec?> = .absent
    var sttEngine: PatchField<STTEngineKind> = .absent
    var cloudSTTProvider: PatchField<CloudSTTProviderKind> = .absent
    var cloudSTTBaseURL: PatchField<String> = .absent
    var cloudSTTModel: PatchField<String> = .absent
    var whisperModel: PatchField<String> = .absent
    var whisperModelChosen: PatchField<Bool> = .absent
    var livePreviewEnabled: PatchField<Bool> = .absent
    var noiseSuppressionEnabled: PatchField<Bool> = .absent
    var edgeLauncherEnabled: PatchField<Bool> = .absent
    var notchpadEnabled: PatchField<Bool> = .absent
    var edgeLauncherEdge: PatchField<LauncherEdge> = .absent
    var edgeLauncherPosition: PatchField<Double> = .absent
    var launcherPanelPosition: PatchField<NormalizedWindowPosition?> = .absent
    var recordingHUDPosition: PatchField<NormalizedWindowPosition?> = .absent
    var transientHUDPosition: PatchField<NormalizedWindowPosition?> = .absent
    var llmProvider: PatchField<LLMProviderKind> = .absent
    var cloudLLMBaseURL: PatchField<String> = .absent
    var cloudLLMModel: PatchField<String> = .absent
    var activeTemplateID: PatchField<String> = .absent
    var recoveryRetention: PatchField<RecoveryRetention> = .absent
    var mediaImportRetention: PatchField<MediaImportRetention> = .absent
    var localContextScope: PatchField<LocalContextScope> = .absent
    var automaticStyleEnabled: PatchField<Bool> = .absent
    var handsFreeMaxMinutes: PatchField<Int> = .absent
    var appRules: PatchField<[String: String]> = .absent
    var languagePin: PatchField<String> = .absent
    var defaultOutputLanguage: PatchField<OutputLanguage> = .absent
    var appLanguageRules: PatchField<[String: String]> = .absent
    var dictationLanguages: PatchField<[String]> = .absent
    var microphoneDeviceUID: PatchField<String?> = .absent
    var vocabularyText: PatchField<String> = .absent
    var voiceCommandsEnabled: PatchField<Bool> = .absent
    var commandKeywords: PatchField<[String]> = .absent
}

/// What each hotkey slot in the quartet (PTT / Insert Last Dictation / Voice Edit / Dictation
/// History Panel, F3) SHOULD become once a patch is applied, resolved WITHOUT touching live
/// state — so it can be validated as a whole before the first write (F1.4) and then applied
/// transactionally (F1.6).
struct HotKeyQuartetTargets {
    let ptt: HotKeySpec
    let insertLastDictation: HotKeySpec?
    let voiceEdit: HotKeySpec?
    let historyPanel: HotKeySpec?
}

extension SettingsPatch {
    @MainActor
    func hotKeyQuartetTargets(current: AppSettings, resetAbsentToDefault: Bool) -> HotKeyQuartetTargets {
        func resolve<T>(_ field: PatchField<T>, currentValue: T, defaultValue: T) -> T {
            switch field {
            case .present(let value): return value
            case .absent: return resetAbsentToDefault ? defaultValue : currentValue
            }
        }
        return HotKeyQuartetTargets(
            ptt: resolve(hotKeySpec, currentValue: current.hotKeySpec, defaultValue: .default),
            insertLastDictation: resolve(insertLastDictationHotKeySpec, currentValue: current.insertLastDictationHotKeySpec, defaultValue: nil),
            voiceEdit: resolve(voiceEditHotKeySpec, currentValue: current.voiceEditHotKeySpec, defaultValue: nil),
            historyPanel: resolve(historyPanelHotKeySpec, currentValue: current.historyPanelHotKeySpec, defaultValue: nil)
        )
    }
}

/// Validates the quartet as a whole — not one setter-at-a-time, whose own sibling-invalidation
/// logic would silently drop a valid-as-a-set combination applied in the wrong order (see
/// PLAN.md F1.6). Every action spec is checked against PTT AND against the OTHER TWO action
/// specs (not just one sibling), using the same centralized `validActionSpec` routine every
/// other path runs (PLAN.md F3.1). Any inconsistency rejects the ENTIRE restore before any write.
private func validateHotKeyQuartet(_ targets: HotKeyQuartetTargets) throws {
    let actions: [(key: String, spec: HotKeySpec?)] = [
        (AppSettings.Keys.insertLastDictationHotKeySpec, targets.insertLastDictation),
        (AppSettings.Keys.voiceEditHotKeySpec, targets.voiceEdit),
        (AppSettings.Keys.historyPanelHotKeySpec, targets.historyPanel)
    ]
    for (index, entry) in actions.enumerated() {
        guard let spec = entry.spec else { continue }
        let otherActionSpecs = actions.enumerated().compactMap { $0.offset == index ? nil : $0.element.spec }
        guard HotKeySpec.validActionSpec(spec, pttSpec: targets.ptt, otherActionSpecs: otherActionSpecs) != nil else {
            throw BackupBundleError.invalidSettingsValue(key: entry.key)
        }
    }
}

private func validateTemplates(_ templates: [Template]) throws {
    guard templates.count <= BackupBundleBounds.maxTemplates else {
        throw BackupBundleError.tooManyTemplates(max: BackupBundleBounds.maxTemplates)
    }
    for template in templates {
        guard template.name.utf8.count <= BackupBundleBounds.maxTemplateNameBytes else {
            throw BackupBundleError.stringTooLong(field: "template name", maxBytes: BackupBundleBounds.maxTemplateNameBytes)
        }
        guard template.prompt.utf8.count <= BackupBundleBounds.maxTemplatePromptBytes else {
            throw BackupBundleError.stringTooLong(field: "template prompt", maxBytes: BackupBundleBounds.maxTemplatePromptBytes)
        }
    }
}

private func validateSnippets(_ snippets: [Snippet]) throws {
    guard snippets.count <= BackupBundleBounds.maxSnippets else {
        throw BackupBundleError.tooManySnippets(max: BackupBundleBounds.maxSnippets)
    }
    for snippet in snippets {
        for trigger in snippet.triggers {
            guard trigger.utf8.count <= BackupBundleBounds.maxSnippetTriggerBytes else {
                throw BackupBundleError.stringTooLong(field: "snippet trigger", maxBytes: BackupBundleBounds.maxSnippetTriggerBytes)
            }
        }
        guard snippet.expansion.utf8.count <= BackupBundleBounds.maxSnippetExpansionBytes else {
            throw BackupBundleError.stringTooLong(field: "snippet expansion", maxBytes: BackupBundleBounds.maxSnippetExpansionBytes)
        }
    }
}

/// Bounds and shape-checks incoming vocab decisions BEFORE any write (PLAN.md PR B, item 2c) —
/// same "validate-all-then-apply" discipline as `validateTemplates`/`validateSnippets`. The
/// table's own `CHECK(status != 'approved' OR surface_term IS NOT NULL)` constraint is
/// duplicated here so a malformed/hand-edited bundle rejects the WHOLE stage up front rather than
/// failing mid-transaction inside `VocabStore.mergeDecisions`. Beyond emptiness/byte length, every
/// restored surface/key must be the SAME shared NFC/control-character/50-byte validator
/// (`AppSettings.validatedVocabularyTerm`) manual and approved terms use everywhere else — a
/// control-containing or noncanonical term must never be committed and reported "imported" only
/// to be silently dropped or re-encoded by `EffectiveVocabulary` later. For an approved decision,
/// `normalizedTerm` must additionally equal the CANONICAL surface's own lowercased form — never
/// independently trusted — so a hand-edited bundle can't name two different spellings under one
/// key (production writes, `VocabStore.approve`/the miner, always produce exactly this
/// relationship). See Codex round 1 finding 6.
private func validateVocabDecisions(_ decisions: [VocabDecision]) throws {
    guard decisions.count <= BackupBundleBounds.maxVocabDecisions else {
        throw BackupBundleError.tooManyVocabDecisions(max: BackupBundleBounds.maxVocabDecisions)
    }
    for decision in decisions {
        guard !decision.normalizedTerm.isEmpty else { throw BackupBundleError.invalidVocabDecisionsSection }
        if decision.status == .approved {
            guard let surfaceTerm = decision.surfaceTerm, !surfaceTerm.isEmpty,
                  let canonicalSurface = AppSettings.validatedVocabularyTerm(surfaceTerm),
                  decision.normalizedTerm == canonicalSurface.lowercased()
            else { throw BackupBundleError.invalidVocabDecisionsSection }
        } else {
            guard let canonicalKey = AppSettings.validatedVocabularyTerm(decision.normalizedTerm),
                  canonicalKey.lowercased() == decision.normalizedTerm
            else { throw BackupBundleError.invalidVocabDecisionsSection }
        }
    }
}

private func validateRuleDict(_ dict: [String: String], field: String) throws {
    guard dict.count <= BackupBundleBounds.maxRuleEntries else {
        throw BackupBundleError.tooManyRuleEntries(field: field, max: BackupBundleBounds.maxRuleEntries)
    }
    for (key, value) in dict {
        guard key.utf8.count <= BackupBundleBounds.maxRuleKeyBytes else {
            throw BackupBundleError.stringTooLong(field: "\(field) key", maxBytes: BackupBundleBounds.maxRuleKeyBytes)
        }
        guard value.utf8.count <= BackupBundleBounds.maxRuleValueBytes else {
            throw BackupBundleError.stringTooLong(field: "\(field) value", maxBytes: BackupBundleBounds.maxRuleValueBytes)
        }
    }
}

/// Decodes a Backup Bundle's `settings` dictionary into a `SettingsPatch`. Reused unchanged for
/// both v1 and v2 (their per-key JSON shapes are identical — see `AppSettings.exportSettingsJSON`/
/// `exportableSettingsSnapshot`); only the caller's absent-key handling differs. Type/enum
/// mismatches reject the WHOLE bundle (validate-all-then-apply, PLAN.md F1.4) rather than
/// silently coercing, unlike the live setters' own robustness-first coercion.
private enum SettingsPatchDecoding {
    // JSON has no distinct boolean NSNumber subtype from Swift's perspective — a JSON `true`
    // bridges to `NSNumber` and satisfies `as? Int`/`as? Double`/`as? Bool` all at once, and a
    // JSON `1` likewise satisfies `as? Bool`. `type(of:)` can't tell them apart either (both
    // box through the same tagged-pointer `NSNumber` machinery), but the underlying CFType
    // does: only a real CFBoolean reports `CFBooleanGetTypeID()`. See P2 finding: JSON
    // booleans silently decoded as 1/1.0 for int/double-typed keys. Shared (not nested in
    // `decode`) so the envelope-level `formatVersion` check below can reuse it too.
    static func isCFBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Rejects CFBoolean and any non-whole-number `NSNumber` (e.g. `5.9`), returning `nil`
    /// instead of throwing so both a keyed settings value and the top-level `formatVersion`
    /// envelope field can apply their own error type. See P2 finding: `formatVersion` decode
    /// still `NSNumber`-bridges a JSON `true` to `Int 1`.
    static func integralValue(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber, !isCFBoolean(number) else { return nil }
        // `NSNumber.intValue` truncates toward zero — a fractional JSON value (e.g.
        // `5.9`) would silently become `5` instead of being rejected. Reject anything
        // that isn't a whole number rather than coerce it. See P2 finding: fractional
        // integer-setting truncation.
        let double = number.doubleValue
        guard double.truncatingRemainder(dividingBy: 1) == 0,
              double >= Double(Int.min), double <= Double(Int.max) else {
            return nil
        }
        return number.intValue
    }

    static func decode(_ dict: [String: Any]) throws -> SettingsPatch {
        typealias Keys = AppSettings.Keys
        var patch = SettingsPatch()

        func str(_ raw: Any, _ key: String) throws -> String {
            guard let value = raw as? String else { throw BackupBundleError.invalidSettingsValue(key: key) }
            return value
        }
        func bool(_ raw: Any, _ key: String) throws -> Bool {
            guard let number = raw as? NSNumber, isCFBoolean(number) else {
                throw BackupBundleError.invalidSettingsValue(key: key)
            }
            return number.boolValue
        }
        func double(_ raw: Any, _ key: String) throws -> Double {
            guard let number = raw as? NSNumber, !isCFBoolean(number) else {
                throw BackupBundleError.invalidSettingsValue(key: key)
            }
            return number.doubleValue
        }
        func int(_ raw: Any, _ key: String) throws -> Int {
            guard let value = integralValue(raw) else {
                throw BackupBundleError.invalidSettingsValue(key: key)
            }
            return value
        }
        func stringDict(_ raw: Any, _ key: String) throws -> [String: String] {
            guard let value = raw as? [String: String] else { throw BackupBundleError.invalidSettingsValue(key: key) }
            return value
        }
        func codable<T: Decodable>(_ type: T.Type, _ raw: Any, _ key: String) throws -> T {
            guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
                  let value = try? JSONDecoder().decode(T.self, from: data) else {
                throw BackupBundleError.invalidSettingsValue(key: key)
            }
            return value
        }
        func windowPosition(_ raw: Any, _ key: String) throws -> NormalizedWindowPosition {
            let value = try codable(NormalizedWindowPosition.self, raw, key)
            guard value.isValid else { throw BackupBundleError.invalidSettingsValue(key: key) }
            return value
        }

        if let raw = dict[Keys.hotKeySpec] {
            patch.hotKeySpec = .present(try codable(HotKeySpec.self, raw, Keys.hotKeySpec))
        }
        if let raw = dict[Keys.insertLastDictationHotKeySpec] {
            patch.insertLastDictationHotKeySpec = raw is NSNull ? .present(nil) : .present(try codable(HotKeySpec.self, raw, Keys.insertLastDictationHotKeySpec))
        }
        if let raw = dict[Keys.voiceEditHotKeySpec] {
            patch.voiceEditHotKeySpec = raw is NSNull ? .present(nil) : .present(try codable(HotKeySpec.self, raw, Keys.voiceEditHotKeySpec))
        }
        if let raw = dict[Keys.historyPanelHotKeySpec] {
            patch.historyPanelHotKeySpec = raw is NSNull ? .present(nil) : .present(try codable(HotKeySpec.self, raw, Keys.historyPanelHotKeySpec))
        }
        if let raw = dict[Keys.sttEngine] {
            guard let value = STTEngineKind(rawValue: try str(raw, Keys.sttEngine)) else { throw BackupBundleError.invalidSettingsValue(key: Keys.sttEngine) }
            patch.sttEngine = .present(value)
        }
        if let raw = dict[Keys.cloudSTTProvider] {
            guard let value = CloudSTTProviderKind(rawValue: try str(raw, Keys.cloudSTTProvider)) else { throw BackupBundleError.invalidSettingsValue(key: Keys.cloudSTTProvider) }
            patch.cloudSTTProvider = .present(value)
        }
        if let raw = dict[Keys.cloudSTTBaseURL] {
            patch.cloudSTTBaseURL = .present(AppSettings.strippedBaseURL(try str(raw, Keys.cloudSTTBaseURL)))
        }
        if let raw = dict[Keys.cloudSTTModel] {
            patch.cloudSTTModel = .present(try str(raw, Keys.cloudSTTModel))
        }
        if let raw = dict[Keys.whisperModel] {
            patch.whisperModel = .present(SpeechModelCatalog.normalize(try str(raw, Keys.whisperModel)))
        }
        if let raw = dict[Keys.whisperModelChosen] {
            patch.whisperModelChosen = .present(try bool(raw, Keys.whisperModelChosen))
        }
        if let raw = dict[Keys.livePreviewEnabled] {
            patch.livePreviewEnabled = .present(try bool(raw, Keys.livePreviewEnabled))
        }
        if let raw = dict[Keys.noiseSuppressionEnabled] {
            patch.noiseSuppressionEnabled = .present(try bool(raw, Keys.noiseSuppressionEnabled))
        }
        if let raw = dict[Keys.edgeLauncherEnabled] {
            patch.edgeLauncherEnabled = .present(try bool(raw, Keys.edgeLauncherEnabled))
        }
        if let raw = dict[Keys.notchpadEnabled] {
            patch.notchpadEnabled = .present(try bool(raw, Keys.notchpadEnabled))
        }
        if let raw = dict[Keys.edgeLauncherEdge] {
            guard let value = LauncherEdge(rawValue: try str(raw, Keys.edgeLauncherEdge)) else { throw BackupBundleError.invalidSettingsValue(key: Keys.edgeLauncherEdge) }
            patch.edgeLauncherEdge = .present(value)
        }
        if let raw = dict[Keys.edgeLauncherPosition] {
            patch.edgeLauncherPosition = .present(AppSettings.clampNormalizedPosition(try double(raw, Keys.edgeLauncherPosition)))
        }
        if let raw = dict[Keys.launcherPanelPosition] {
            patch.launcherPanelPosition = raw is NSNull ? .present(nil) : .present(try windowPosition(raw, Keys.launcherPanelPosition))
        }
        if let raw = dict[Keys.recordingHUDPosition] {
            patch.recordingHUDPosition = raw is NSNull ? .present(nil) : .present(try windowPosition(raw, Keys.recordingHUDPosition))
        }
        if let raw = dict[Keys.transientHUDPosition] {
            patch.transientHUDPosition = raw is NSNull ? .present(nil) : .present(try windowPosition(raw, Keys.transientHUDPosition))
        }
        if let raw = dict[Keys.llmProvider] {
            guard let value = LLMProviderKind(rawValue: try str(raw, Keys.llmProvider)) else { throw BackupBundleError.invalidSettingsValue(key: Keys.llmProvider) }
            patch.llmProvider = .present(value)
        }
        if let raw = dict[Keys.cloudLLMBaseURL] {
            patch.cloudLLMBaseURL = .present(AppSettings.strippedBaseURL(try str(raw, Keys.cloudLLMBaseURL)))
        }
        if let raw = dict[Keys.cloudLLMModel] {
            patch.cloudLLMModel = .present(try str(raw, Keys.cloudLLMModel))
        }
        if let raw = dict[Keys.activeTemplateID] {
            patch.activeTemplateID = .present(try str(raw, Keys.activeTemplateID))
        }
        if let raw = dict[Keys.recoveryRetention] {
            guard let value = RecoveryRetention(rawValue: try int(raw, Keys.recoveryRetention)) else { throw BackupBundleError.invalidSettingsValue(key: Keys.recoveryRetention) }
            patch.recoveryRetention = .present(value)
        }
        if let raw = dict[Keys.mediaImportRetention] {
            guard let value = MediaImportRetention(rawValue: try int(raw, Keys.mediaImportRetention)) else { throw BackupBundleError.invalidSettingsValue(key: Keys.mediaImportRetention) }
            patch.mediaImportRetention = .present(value)
        }
        if let raw = dict[Keys.localContextScope] {
            guard let value = LocalContextScope(rawValue: try str(raw, Keys.localContextScope)) else { throw BackupBundleError.invalidSettingsValue(key: Keys.localContextScope) }
            patch.localContextScope = .present(value)
        }
        if let raw = dict[Keys.automaticStyleEnabled] {
            patch.automaticStyleEnabled = .present(try bool(raw, Keys.automaticStyleEnabled))
        }
        if let raw = dict[Keys.handsFreeMaxMinutes] {
            patch.handsFreeMaxMinutes = .present(AppSettings.clampHandsFreeMaxMinutes(try int(raw, Keys.handsFreeMaxMinutes)))
        }
        if let raw = dict[Keys.appRules] {
            let value = try stringDict(raw, Keys.appRules)
            try validateRuleDict(value, field: "appRules")
            patch.appRules = .present(value)
        }
        // Decode-time normalization validates against the FULL curated 8 (`DictationLanguage`),
        // not yet the specific `dictationLanguages` set this same bundle may also restore —
        // that narrower, set-change coercion happens at apply time via each property's own
        // didSet once `dictationLanguages` has actually landed (see `applySettingsPatch`'s
        // ordering comment and PLAN.md F5.4). This decode step only rejects garbage/unknown
        // codes, the same domain-safety role it played before F5 introduced a configurable set.
        let curatedCodes = DictationLanguage.allCases.map(\.rawValue)
        if let raw = dict[Keys.languagePin] {
            patch.languagePin = .present(AppSettings.normalizeLanguagePin(try str(raw, Keys.languagePin), allowed: curatedCodes))
        }
        if let raw = dict[Keys.defaultOutputLanguage] {
            // `OutputLanguage.persisted` is intentionally lenient (falls back to `.sameAsSpoken`)
            // for reading old/foreign UserDefaults values at app launch — that fallback doesn't
            // belong here. Restore is validate-then-apply: an unknown raw value must reject the
            // whole bundle naming this key, not silently coerce. See P2 finding: invalid
            // `defaultOutputLanguage` silently coerced instead of throwing.
            guard let value = OutputLanguage(rawValue: try str(raw, Keys.defaultOutputLanguage)) else {
                throw BackupBundleError.invalidSettingsValue(key: Keys.defaultOutputLanguage)
            }
            patch.defaultOutputLanguage = .present(value)
        }
        if let raw = dict[Keys.appLanguageRules] {
            let value = try stringDict(raw, Keys.appLanguageRules)
            try validateRuleDict(value, field: "appLanguageRules")
            patch.appLanguageRules = .present(AppSettings.sanitizedLanguageRules(value, allowed: curatedCodes))
        }
        if let raw = dict[Keys.dictationLanguages] {
            guard let value = raw as? [String] else { throw BackupBundleError.invalidSettingsValue(key: Keys.dictationLanguages) }
            patch.dictationLanguages = .present(AppSettings.normalizeDictationLanguages(value))
        }
        if let raw = dict[Keys.microphoneDeviceUID] {
            patch.microphoneDeviceUID = raw is NSNull ? .present(nil) : .present(try str(raw, Keys.microphoneDeviceUID))
        }
        if let raw = dict[Keys.vocabularyText] {
            patch.vocabularyText = .present(AppSettings.clampVocabularyRawText(try str(raw, Keys.vocabularyText)))
        }
        if let raw = dict[Keys.voiceCommandsEnabled] {
            patch.voiceCommandsEnabled = .present(try bool(raw, Keys.voiceCommandsEnabled))
        }
        if let raw = dict[Keys.commandKeywords] {
            guard let value = raw as? [String] else { throw BackupBundleError.invalidSettingsValue(key: Keys.commandKeywords) }
            patch.commandKeywords = .present(AppSettings.normalizeCommandKeywords(value))
        }

        return patch
    }
}

extension AppSettings {
    /// Applies `patch` to `self`. `resetAbsentToDefault`: v2 semantics — every exportable key not
    /// present in the bundle resets to its documented default — when `true`; v1 legacy semantics
    /// — an absent key is left untouched, nothing resets — when `false`. `templateIDMap` rewrites
    /// `activeTemplateID`/`appRules` values through the old→new template ID map produced by the
    /// templates-import stage, which MUST run before this. See PLAN.md F1.5/F1.6.
    ///
    /// Apply order is NOT the key list's order — several setters have side effects on other
    /// exportable keys (`llmProvider`'s didSet can overwrite `cloudLLMBaseURL`/`cloudLLMModel`;
    /// `edgeLauncherEdge`/`edgeLauncherPosition`'s didSets null `launcherPanelPosition`), so those
    /// clusters are ordered so the more specific value always lands and sticks last.
    func applySettingsPatch(_ patch: SettingsPatch, resetAbsentToDefault: Bool, templateIDMap: [String: String]) {
        func apply<T>(_ field: PatchField<T>, default defaultValue: T, _ set: (T) -> Void) {
            switch field {
            case .present(let value): set(value)
            case .absent: if resetAbsentToDefault { set(defaultValue) }
            }
        }

        // 1. LLM provider cluster: provider first (its didSet can overwrite baseURL/model with
        //    provider defaults), then the exact restored baseURL/model land last and stick. An
        //    ABSENT baseURL/model's default is resolved from the EFFECTIVE RESTORED provider
        //    (just set above) — not a hardcoded provider — so a v2 bundle that restores
        //    `.ollama` but omits `cloudLLMBaseURL`/`cloudLLMModel` lands on Ollama's own
        //    defaults, never Anthropic's. See Codex finding: cross-provider endpoint/model mix
        //    on partial v2 restore.
        apply(patch.llmProvider, default: .anthropic) { llmProvider = $0 }
        let providerDefaults = Self.resolveProviderDefaults(provider: llmProvider, baseURL: "", model: "")
        apply(patch.cloudLLMBaseURL, default: providerDefaults.baseURL) { cloudLLMBaseURL = $0 }
        apply(patch.cloudLLMModel, default: providerDefaults.model) { cloudLLMModel = $0 }

        // 2. Cloud STT provider cluster: provider first (its didSet can set the base URL/model
        // defaults), then the exact restored base URL/model land last and stick. An absent
        // base/model under v2 resolves against the effective restored provider.
        apply(patch.cloudSTTProvider, default: .openAI) { cloudSTTProvider = $0 }
        let cloudSTTDefaults = Self.resolveCloudSTTDefaults(provider: cloudSTTProvider, baseURL: "", model: "")
        apply(patch.cloudSTTBaseURL, default: cloudSTTDefaults.baseURL) { cloudSTTBaseURL = $0 }
        apply(patch.cloudSTTModel, default: cloudSTTDefaults.model) { cloudSTTModel = $0 }

        // 3. Whisper model cluster: `whisperModel` is `private(set)`, applied through
        //    `applyAutomaticWhisperModel` (normalizes; leaves `whisperModelChosen` untouched, so
        //    that key is applied separately right after).
        apply(patch.whisperModel, default: SpeechModelCatalog.normalize(SpeechModelCatalog.defaultID)) { applyAutomaticWhisperModel($0) }
        apply(patch.whisperModelChosen, default: false) { whisperModelChosen = $0 }

        // 4. Launcher-position cluster: edge + position first — both call
        //    `resetLauncherPanelPosition()` (nils it) on change — then the restored panel
        //    position last, so it isn't immediately wiped by the two setters above it.
        apply(patch.edgeLauncherEdge, default: .right) { edgeLauncherEdge = $0 }
        apply(patch.edgeLauncherPosition, default: 0.5) { edgeLauncherPosition = $0 }
        apply(patch.launcherPanelPosition, default: nil) { launcherPanelPosition = $0 }

        // 5. Hotkey quartet, applied transactionally (clear all three action specs, set PTT,
        //    then each action spec) — see `applyHotKeyQuartet`. Already validated as a consistent
        //    set before restore's first write (`validateHotKeyQuartet`, called from
        //    `BackupBundle.restore`).
        applyHotKeyQuartet(patch.hotKeyQuartetTargets(current: self, resetAbsentToDefault: resetAbsentToDefault))

        // 6. `activeTemplateID`/`appRules` rewritten through the templates-import ID map so a
        //    restored reference never dangles — including one that pointed at a deduplicated
        //    incoming template (see `TemplateStore.importTemplates`).
        apply(patch.activeTemplateID, default: Template.defaultID) { activeTemplateID = templateIDMap[$0] ?? $0 }
        apply(patch.appRules, default: [:]) { rules in appRules = rules.mapValues { templateIDMap[$0] ?? $0 } }

        // 6b. Dictation Language Set cluster: `dictationLanguages` MUST land before
        //     `languagePin`/`appLanguageRules` below — its didSet re-validates both against the
        //     restored set (PLAN.md F5.4's set-change coercion), so applying it first means the
        //     restored pin/rules are checked against their FINAL sibling value rather than
        //     whatever `dictationLanguages` happened to hold before this restore.
        apply(patch.dictationLanguages, default: AppSettings.defaultDictationLanguages) { dictationLanguages = $0 }

        // 7. Everything else — order-independent.
        apply(patch.sttEngine, default: .whisperKit) { sttEngine = $0 }
        apply(patch.livePreviewEnabled, default: true) { livePreviewEnabled = $0 }
        apply(patch.noiseSuppressionEnabled, default: true) { noiseSuppressionEnabled = $0 }
        apply(patch.edgeLauncherEnabled, default: false) { edgeLauncherEnabled = $0 }
        apply(patch.notchpadEnabled, default: false) { notchpadEnabled = $0 }
        apply(patch.recordingHUDPosition, default: nil) { recordingHUDPosition = $0 }
        apply(patch.transientHUDPosition, default: nil) { transientHUDPosition = $0 }
        apply(patch.recoveryRetention, default: .sevenDays) { recoveryRetention = $0 }
        apply(patch.mediaImportRetention, default: .default) { mediaImportRetention = $0 }
        apply(patch.localContextScope, default: .off) { localContextScope = $0 }
        apply(patch.automaticStyleEnabled, default: false) { automaticStyleEnabled = $0 }
        apply(patch.handsFreeMaxMinutes, default: 5) { handsFreeMaxMinutes = $0 }
        apply(patch.languagePin, default: "auto") { languagePin = $0 }
        apply(patch.defaultOutputLanguage, default: .sameAsSpoken) { defaultOutputLanguage = $0 }
        apply(patch.appLanguageRules, default: [:]) { appLanguageRules = $0 }
        apply(patch.microphoneDeviceUID, default: nil) { microphoneDeviceUID = $0 }
        apply(patch.vocabularyText, default: "") { vocabularyText = $0 }
        apply(patch.voiceCommandsEnabled, default: false) { voiceCommandsEnabled = $0 }
        apply(patch.commandKeywords, default: AppSettings.defaultCommandKeywords) { commandKeywords = $0 }
    }

    /// Clears both action specs, sets PTT, then re-applies each action spec in turn — so no
    /// setter's own sibling-invalidation `didSet` logic (see HotKeySpec.swift/AppSettings.swift)
    /// ever observes a STALE intermediate value of a spec that's about to be overwritten anyway.
    /// `targets` must already be validated as a mutually-consistent set (`validateHotKeyQuartet`)
    /// before this runs. See PLAN.md F1.6.
    fileprivate func applyHotKeyQuartet(_ targets: HotKeyQuartetTargets) {
        insertLastDictationHotKeySpec = nil
        voiceEditHotKeySpec = nil
        historyPanelHotKeySpec = nil
        hotKeySpec = targets.ptt
        insertLastDictationHotKeySpec = targets.insertLastDictation
        voiceEditHotKeySpec = targets.voiceEdit
        historyPanelHotKeySpec = targets.historyPanel
    }
}

/// Assembles/restores the single-JSON Backup Bundle (Settings → Storage → Back Up…/Restore…).
/// Config-only: settings + templates + snippets — no Dictation History, no Scratchpad, no zip.
/// See PLAN.md F1.
@MainActor
enum BackupBundle {
    static let fileName = "FreeTalker Backup.json"

    /// Every exportable key at its current normalized value (v2 completeness, PLAN.md F1.2),
    /// every template, every snippet, and every self-learning-vocabulary decision — reading
    /// `TemplateStore.templates`, `SnippetStore.snippets()`, and `VocabStore.decisions()` directly
    /// rather than touching Dictation History/Scratchpad storage at all (out of scope, PLAN.md
    /// "Out of scope"). `vocabStore` is optional — a `nil` (e.g. it failed to initialize this
    /// session, see `AppCoordinator`) simply omits the `vocabDecisions` key rather than failing
    /// the whole backup; `restore` treats an absent key as "nothing to merge", not an error.
    /// Evidence (the transcript-derived recurrence data behind suggestions) is deliberately NOT
    /// exported — see PLAN.md PR B, item 2c.
    static func export(settings: AppSettings, templateStore: TemplateStore, snippetStore: SnippetStore, vocabStore: VocabStore? = nil) async throws -> Data {
        let settingsDict = settings.exportableSettingsSnapshot()
        let templatesJSON = try jsonArray(from: templateStore.templates)
        let snippets = try await snippetStore.snippets()
        let snippetsJSON = try jsonArray(from: snippets)
        var payload: [String: Any] = [
            "formatVersion": 2,
            "app": "FreeTalker",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "settings": settingsDict,
            "templates": templatesJSON,
            "snippets": snippetsJSON
        ]
        if let vocabStore {
            let decisions = try await vocabStore.decisions()
            // Export enforces the SAME 2,000-decision bound and full shared-validator check
            // `restore` requires (PLAN.md PR B, item 2c) — otherwise a store that somehow
            // accumulated more decisions than the cap, or (defense in depth) a row that
            // wouldn't itself pass the shared validator, would produce a bundle FreeTalker's own
            // restore then unconditionally rejects. See Codex round 1 finding 8.
            try validateVocabDecisions(decisions)
            payload["vocabDecisions"] = try jsonArray(from: decisions)
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    /// Validate-all-then-apply (PLAN.md F1.4): envelope, then the ENTIRE bundle (types, bounds,
    /// the hotkey trio as a whole) are validated before the first write. Apply order is
    /// templates → snippets → settings (F1.5); a stage failure after an earlier one committed
    /// throws `.stageFailed` carrying exactly what was applied so far — no silent partial
    /// restore. v1 bundles (`formatVersion == 1`) are settings-only: templates/snippets stages
    /// are skipped and absent settings keys are left untouched rather than reset (F1.6).
    @discardableResult
    static func restore(data: Data, settings: AppSettings, templateStore: TemplateStore, snippetStore: SnippetStore, vocabStore: VocabStore? = nil) async throws -> BackupBundleImportResult {
        guard data.count <= BackupBundleBounds.maxFileBytes else {
            throw BackupBundleError.fileTooLarge(maxBytes: BackupBundleBounds.maxFileBytes)
        }
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BackupBundleError.invalidEnvelope
        }
        guard top["app"] as? String == "FreeTalker" else {
            throw BackupBundleError.notFreeTalkerBundle
        }
        // Same CFBoolean-rejection + integral check as keyed settings values (see
        // `SettingsPatchDecoding.integralValue`) — otherwise a JSON `true` NSNumber-bridges to
        // `Int 1` and a corrupted/edited v1 backup is silently accepted. See P2 finding.
        let formatVersionValue = top["formatVersion"].flatMap(SettingsPatchDecoding.integralValue)
        guard let formatVersion = formatVersionValue, formatVersion == 1 || formatVersion == 2 else {
            throw BackupBundleError.unsupportedFormatVersion(formatVersionValue ?? -1)
        }

        // v2 resets every absent settings key to its default (`resetAbsentToDefault` below) — if
        // `settings` were silently treated as `{}` here (missing key, or present but not a
        // dictionary), that reset would fire against an EMPTY patch and wipe every setting after
        // templates/snippets had already been imported. v1 is settings-only and already leaves
        // absent keys untouched, so this envelope-level requirement is v2-specific. See Codex
        // finding: v2 bundle with a missing/malformed `settings` key silently resets everything.
        let resetAbsentToDefault = formatVersion == 2
        let settingsDict: [String: Any]
        if resetAbsentToDefault {
            guard let dict = top["settings"] as? [String: Any] else {
                throw BackupBundleError.invalidSettingsSection
            }
            settingsDict = dict
        } else {
            settingsDict = (top["settings"] as? [String: Any]) ?? [:]
        }
        let patch = try SettingsPatchDecoding.decode(settingsDict)

        var templates: [Template] = []
        var snippets: [Snippet] = []
        if formatVersion == 2 {
            guard let templatesRaw = top["templates"] else { throw BackupBundleError.invalidTemplatesSection }
            templates = try decodeArray(Template.self, templatesRaw, error: .invalidTemplatesSection)
            try validateTemplates(templates)

            guard let snippetsRaw = top["snippets"] else { throw BackupBundleError.invalidSnippetsSection }
            snippets = try decodeArray(Snippet.self, snippetsRaw, error: .invalidSnippetsSection)
            try validateSnippets(snippets)
        }

        // Vocab decisions (PLAN.md PR B, item 2c) are a NAMED, OPTIONAL stage — unlike
        // templates/snippets above, an absent `vocabDecisions` key is not an error: it means
        // either an older backup predating this feature, or one exported while `vocabStore`
        // itself was unavailable (see `export`'s doc comment). Bounded/validated in full here,
        // before any write, same as every other section.
        var vocabDecisions: [VocabDecision] = []
        if formatVersion == 2, let vocabDecisionsRaw = top["vocabDecisions"] {
            vocabDecisions = try decodeArray(VocabDecision.self, vocabDecisionsRaw, error: .invalidVocabDecisionsSection)
            try validateVocabDecisions(vocabDecisions)
        }

        // The hotkey trio is validated as a WHOLE before any write — see F1.6 and
        // `validateHotKeyQuartet`'s doc comment for why a per-setter loop can't do this safely.
        try validateHotKeyQuartet(patch.hotKeyQuartetTargets(current: settings, resetAbsentToDefault: resetAbsentToDefault))

        var result = BackupBundleImportResult()
        var templateIDMap: [String: String] = [:]

        if formatVersion == 2 {
            do {
                let templateResult = try templateStore.importTemplates(templates)
                templateIDMap = templateResult.idMap
                result.templatesImported = templateResult.importedCount
                result.templatesSkipped = templateResult.skippedCount
            } catch {
                throw BackupBundleError.stageFailed(stage: "templates", partial: result, underlying: error.localizedDescription)
            }

            do {
                let snippetResult = try await snippetStore.importSnippets(snippets)
                result.snippetsImported = snippetResult.importedCount
                result.snippetsSkipped = snippetResult.skippedCount
            } catch {
                throw BackupBundleError.stageFailed(stage: "snippets", partial: result, underlying: error.localizedDescription)
            }
        }

        if !vocabDecisions.isEmpty {
            // The bundle DOES carry decisions to apply — a `nil` destination `vocabStore` here
            // must fail this named stage explicitly, never report a plain success that silently
            // dropped every restored approve/dismiss decision (indistinguishable, before this
            // fix, from "the bundle simply had none"). An EMPTY/absent `vocabDecisions` section
            // still skips silently above — genuinely nothing to apply, not a failure. See Codex
            // round 1 finding 7.
            guard let vocabStore else {
                throw BackupBundleError.stageFailed(
                    stage: "vocabDecisions", partial: result,
                    underlying: "Vocabulary suggestions storage isn't available."
                )
            }
            do {
                let mergeResult = try await vocabStore.mergeDecisions(vocabDecisions)
                result.vocabDecisionsImported = mergeResult.merged
                result.vocabDecisionsSkipped = mergeResult.skipped
            } catch {
                throw BackupBundleError.stageFailed(stage: "vocabDecisions", partial: result, underlying: error.localizedDescription)
            }
        }

        settings.applySettingsPatch(patch, resetAbsentToDefault: resetAbsentToDefault, templateIDMap: templateIDMap)
        result.settingsApplied = true
        return result
    }

    private static func jsonArray<T: Encodable>(from items: [T]) throws -> [[String: Any]] {
        try items.map { item in
            let data = try JSONEncoder().encode(item)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BackupBundleError.invalidEnvelope
            }
            return dict
        }
    }

    private static func decodeArray<T: Decodable>(_ type: T.Type, _ raw: Any, error: BackupBundleError) throws -> [T] {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
              let items = try? JSONDecoder().decode([T].self, from: data) else {
            throw error
        }
        return items
    }
}
