import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct BackupBundleTests {
    // MARK: - Envelope validation (PLAN.md F1.4: gate BEFORE section decoding)

    @Test func rejectsWrongAppName() async throws {
        let env = try makeEnv()
        let data = try json(["app": "NotFreeTalker", "formatVersion": 2, "settings": [String: Any]()])

        await #expect(throws: BackupBundleError.notFreeTalkerBundle) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
    }

    @Test func rejectsUnsupportedFormatVersion() async throws {
        let env = try makeEnv()
        let data = try json(["app": "FreeTalker", "formatVersion": 3, "settings": [String: Any]()])

        await #expect(throws: BackupBundleError.unsupportedFormatVersion(3)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
    }

    @Test func rejectsABooleanFormatVersionInsteadOfBridgingToOne() async throws {
        // A JSON `true` NSNumber-bridges to `Int 1` — without the CFBoolean rejection a
        // corrupted/edited v2 backup with `formatVersion: true` would be silently accepted as
        // v1 (settings-only), skipping templates/snippets with a success report. See P2 finding.
        let env = try makeEnv()
        let data = try json(["app": "FreeTalker", "formatVersion": true, "settings": [String: Any]()])

        await #expect(throws: BackupBundleError.unsupportedFormatVersion(-1)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
    }

    @Test func rejectsOversizedFile() async throws {
        let env = try makeEnv()
        let padding = String(repeating: "a", count: 6 * 1024 * 1024)
        let data = try json(["app": "FreeTalker", "formatVersion": 2, "settings": [String: Any](), "pad": padding])

        await #expect(throws: BackupBundleError.fileTooLarge(maxBytes: 5 * 1024 * 1024)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
    }

    // MARK: - Bounds (PLAN.md F1.4: new per-string/per-collection limits)

    @Test func rejectsTooManyTemplates() async throws {
        let env = try makeEnv()
        let templates = (0..<501).map { Template(id: "t\($0)", name: "T\($0)", prompt: "p") }
        let data = try json(v2Payload(templates: try encodeArray(templates)))

        await #expect(throws: BackupBundleError.tooManyTemplates(max: 500)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        #expect(env.templateStore.templates.count == Template.builtIns.count)
    }

    @Test func rejectsOversizedTemplatePrompt() async throws {
        let env = try makeEnv()
        let templates = [Template(id: "big", name: "Big", prompt: String(repeating: "x", count: 50_001))]
        let data = try json(v2Payload(templates: try encodeArray(templates)))

        await #expect(throws: BackupBundleError.stringTooLong(field: "template prompt", maxBytes: 50_000)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
    }

    @Test func rejectsTooManySnippets() async throws {
        let env = try makeEnv()
        let now = Date()
        let snippets = (0..<1001).map {
            Snippet(id: "s\($0)", name: "S\($0)", triggers: ["trig\($0)"], expansion: "e", createdAt: now, updatedAt: now)
        }
        let data = try json(v2Payload(snippets: try encodeArray(snippets)))

        await #expect(throws: BackupBundleError.tooManySnippets(max: 1_000)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        #expect(try await env.snippetStore.snippets().isEmpty)
    }

    @Test func rejectsOversizedSnippetTrigger() async throws {
        let env = try makeEnv()
        let now = Date()
        let snippets = [Snippet(id: "s", name: "S", triggers: [String(repeating: "t", count: 501)], expansion: "e", createdAt: now, updatedAt: now)]
        let data = try json(v2Payload(snippets: try encodeArray(snippets)))

        await #expect(throws: BackupBundleError.stringTooLong(field: "snippet trigger", maxBytes: 500)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
    }

    @Test func rejectsFractionalValueForAnIntegerSettingInsteadOfTruncating() async throws {
        // A JSON number with a fractional part for an integer-typed key (handsFreeMaxMinutes)
        // must reject the whole bundle naming the key, not silently truncate 5.9 -> 5 via
        // NSNumber.intValue. See P2 finding: integer decode truncates fractional JSON silently.
        let env = try makeEnv()
        env.settings.handsFreeMaxMinutes = 20
        let data = try json(v2Payload(settings: ["handsFreeMaxMinutes": 5.9]))

        await #expect(throws: BackupBundleError.invalidSettingsValue(key: AppSettings.Keys.handsFreeMaxMinutes)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        // Reject-before-write: the pre-restore value is untouched.
        #expect(env.settings.handsFreeMaxMinutes == 20)
    }

    @Test func acceptsAWholeNumberJSONValueForAnIntegerSetting() async throws {
        // Guards the fractional-reject change against over-rejecting: a whole-number double
        // (JSON has no int/double distinction) still decodes cleanly.
        let env = try makeEnv()
        let data = try json(v2Payload(settings: ["handsFreeMaxMinutes": 7.0]))

        _ = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        #expect(env.settings.handsFreeMaxMinutes == 7)
    }

    @Test func rejectsABooleanJSONValueForAnIntegerSetting() async throws {
        // A JSON `true`/`false` bridges to `NSNumber` and satisfies `as? Int` (as `1`/`0`) just
        // like a real integer would — reject it instead of silently decoding
        // `handsFreeMaxMinutes: true` as `1`. See P2 finding: JSON booleans bridge to NSNumber
        // and silently decode as 1 for int-typed keys.
        let env = try makeEnv()
        env.settings.handsFreeMaxMinutes = 20
        let data = try json(v2Payload(settings: ["handsFreeMaxMinutes": true]))

        await #expect(throws: BackupBundleError.invalidSettingsValue(key: AppSettings.Keys.handsFreeMaxMinutes)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        #expect(env.settings.handsFreeMaxMinutes == 20)
    }

    @Test func rejectsABooleanJSONValueForADoubleSetting() async throws {
        // Same bridging hazard as the integer case, for a double-typed key:
        // `edgeLauncherPosition: true` must not silently decode as `1.0`.
        let env = try makeEnv()
        env.settings.edgeLauncherPosition = 0.25
        let data = try json(v2Payload(settings: ["edgeLauncherPosition": true]))

        await #expect(throws: BackupBundleError.invalidSettingsValue(key: AppSettings.Keys.edgeLauncherPosition)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        #expect(env.settings.edgeLauncherPosition == 0.25)
    }

    @Test func rejectsANumericJSONValueForABooleanSetting() async throws {
        // Symmetric with the int/double fix above: `raw as? Bool` also succeeds for a plain
        // numeric `NSNumber` (`1 as? Bool == true`), so a JSON `1` for a boolean-typed key
        // (`noiseSuppressionEnabled`) must reject rather than silently decode as `true`. Locks in
        // the reject-numeric-for-bool direction of the symmetry fix. See P2 finding: bool decode
        // helper's reciprocal bridging hazard.
        let env = try makeEnv()
        env.settings.noiseSuppressionEnabled = true
        let data = try json(v2Payload(settings: ["noiseSuppressionEnabled": 1]))

        await #expect(throws: BackupBundleError.invalidSettingsValue(key: AppSettings.Keys.noiseSuppressionEnabled)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        #expect(env.settings.noiseSuppressionEnabled == true)
    }

    @Test func acceptsARealJSONBooleanForABooleanSetting() async throws {
        // Guards the symmetry fix against over-rejecting: an actual JSON `false` still decodes
        // cleanly for a boolean-typed key.
        let env = try makeEnv()
        env.settings.noiseSuppressionEnabled = true
        let data = try json(v2Payload(settings: ["noiseSuppressionEnabled": false]))

        _ = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        #expect(env.settings.noiseSuppressionEnabled == false)
    }

    @Test func rejectsAnUnknownDefaultOutputLanguageInsteadOfCoercingToSameAsSpoken() async throws {
        // `OutputLanguage.persisted` coerces any unrecognized raw value to `.sameAsSpoken` — that
        // leniency is correct for reading old/foreign UserDefaults at app launch, but restore is
        // validate-then-apply: an unknown raw value must reject the whole bundle naming this key.
        // See P2 finding: invalid defaultOutputLanguage silently coerced instead of throwing.
        let env = try makeEnv()
        env.settings.defaultOutputLanguage = .english
        let data = try json(v2Payload(settings: ["defaultOutputLanguage": "klingon"]))

        await #expect(throws: BackupBundleError.invalidSettingsValue(key: AppSettings.Keys.defaultOutputLanguage)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        #expect(env.settings.defaultOutputLanguage == .english)
    }

    @Test func rejectsTooManyAppRulesEntries() async throws {
        let env = try makeEnv()
        var appRules: [String: String] = [:]
        for index in 0..<201 { appRules["com.example.app\(index)"] = "clean-dictation" }
        let data = try json(v2Payload(settings: ["appRules": appRules]))

        await #expect(throws: BackupBundleError.tooManyRuleEntries(field: "appRules", max: 200)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
    }

    // MARK: - v1 legacy acceptance (PLAN.md F1.6: only present keys applied, nothing reset)

    @Test func v1AcceptsSettingsOnlyAndLeavesAbsentKeysUntouched() async throws {
        let env = try makeEnv()
        env.settings.languagePin = "en"
        env.settings.handsFreeMaxMinutes = 20

        let data = try json(["app": "FreeTalker", "formatVersion": 1, "settings": ["noiseSuppressionEnabled": false]])
        let result = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)

        #expect(result.settingsApplied)
        #expect(env.settings.noiseSuppressionEnabled == false)
        // Absent under v1: left exactly as they were before restore, not reset to default.
        #expect(env.settings.languagePin == "en")
        #expect(env.settings.handsFreeMaxMinutes == 20)
    }

    @Test func v2ResetsAbsentKeysToDefault() async throws {
        let env = try makeEnv()
        env.settings.languagePin = "en"

        var settingsDict = env.settings.exportableSettingsSnapshot()
        settingsDict.removeValue(forKey: "languagePin")
        let data = try json(v2Payload(settings: settingsDict))

        _ = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)

        #expect(env.settings.languagePin == "auto")
    }

    // MARK: - v2 envelope requires a `settings` dictionary (Codex finding: missing/malformed
    // `settings` silently resets everything after templates/snippets already imported)

    @Test func v2RejectsMissingSettingsSectionBeforeAnyWrites() async throws {
        let env = try makeEnv()
        env.settings.languagePin = "en"
        let now = Date()
        let templates = try encodeArray([Template(id: "t", name: "T", prompt: "p")])
        let snippets = try encodeArray([Snippet(id: "s", name: "S", triggers: ["trig"], expansion: "e", createdAt: now, updatedAt: now)])
        var payload = v2Payload(templates: templates, snippets: snippets)
        payload.removeValue(forKey: "settings")
        let data = try json(payload)

        await #expect(throws: BackupBundleError.invalidSettingsSection) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        // Nothing was imported — the envelope-level check runs before the templates/snippets
        // stages, and never resets `languagePin` to default either.
        #expect(env.templateStore.templates.count == Template.builtIns.count)
        #expect(try await env.snippetStore.snippets().isEmpty)
        #expect(env.settings.languagePin == "en")
    }

    @Test func v2RejectsNonDictionarySettingsSectionBeforeAnyWrites() async throws {
        let env = try makeEnv()
        env.settings.languagePin = "en"
        var payload = v2Payload()
        payload["settings"] = "not-a-dictionary"
        let data = try json(payload)

        await #expect(throws: BackupBundleError.invalidSettingsSection) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
        #expect(env.settings.languagePin == "en")
    }

    // MARK: - Snippet dedupe/skip counts (PLAN.md F1.7)

    @Test func snippetImportSkipsCollidingTriggerAndReportsCounts() async throws {
        let env = try makeEnv()
        _ = try await env.snippetStore.create(name: "Existing", triggers: ["brb"], expansion: "be right back")

        let now = Date()
        let snippets = [
            Snippet(id: "new", name: "New", triggers: ["ttyl"], expansion: "talk to you later", createdAt: now, updatedAt: now),
            Snippet(id: "dup", name: "Dup", triggers: ["brb"], expansion: "different expansion", createdAt: now, updatedAt: now)
        ]
        let data = try json(v2Payload(snippets: try encodeArray(snippets)))
        let result = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)

        #expect(result.snippetsImported == 1)
        #expect(result.snippetsSkipped == 1)
        let stored = try await env.snippetStore.snippets()
        #expect(stored.contains { $0.name == "New" })
        // Existing wins: the pre-existing "brb" snippet's expansion is unchanged.
        let brb = try await env.snippetStore.match("brb")
        #expect(brb == .match(try #require(stored.first { $0.name == "Existing" })))
    }

    // MARK: - Template ID remap of activeTemplateID/appRules (PLAN.md F1.5)

    @Test func remapsActiveTemplateIDThroughFreshIDOnCollision() async throws {
        let env = try makeEnv()
        try env.templateStore.upsert(Template(id: "custom-1", name: "Pre-existing", prompt: "unrelated"))
        env.settings.activeTemplateID = "custom-1"

        let templates = [Template(id: "custom-1", name: "Incoming", prompt: "incoming prompt")]
        var settingsDict = env.settings.exportableSettingsSnapshot()
        settingsDict["activeTemplateID"] = "custom-1"
        let data = try json(v2Payload(settings: settingsDict, templates: try encodeArray(templates)))

        _ = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)

        let imported = try #require(env.templateStore.templates.first { $0.name == "Incoming" })
        #expect(imported.id != "custom-1")
        // activeTemplateID was rewritten to the freshly-minted id, not left dangling at "custom-1".
        #expect(env.settings.activeTemplateID == imported.id)
    }

    @Test func remapsAppRulesThroughDedupedExistingID() async throws {
        let env = try makeEnv()
        try env.templateStore.upsert(Template(id: "existing-dupe-target", name: "Shared Content", prompt: "shared prompt"))

        let templates = [Template(id: "incoming-dup", name: "Shared Content", prompt: "shared prompt")]
        var settingsDict = env.settings.exportableSettingsSnapshot()
        settingsDict["appRules"] = ["com.example.foo": "incoming-dup"]
        let data = try json(v2Payload(settings: settingsDict, templates: try encodeArray(templates)))

        let result = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)

        #expect(result.templatesSkipped == 1)
        #expect(env.settings.appRules["com.example.foo"] == "existing-dupe-target")
    }

    // MARK: - URL userinfo redaction (PLAN.md F1.3)

    @Test func setterStripsUserinfoQueryAndFragmentFromBaseURL() throws {
        let env = try makeEnv()
        env.settings.cloudLLMBaseURL = "https://user:pass@api.example.com:8443/v1?token=secret#frag"
        #expect(env.settings.cloudLLMBaseURL == "https://api.example.com:8443/v1")
        #expect(!env.settings.cloudLLMBaseURL.contains("user"))
        #expect(!env.settings.cloudLLMBaseURL.contains("pass"))
        #expect(!env.settings.cloudLLMBaseURL.contains("token"))
    }

    @Test func urlStrippingIsIdempotent() {
        let inputs = [
            "https://user:pass@api.example.com:8443/v1?token=secret#frag",
            "https://api.example.com/v1",
            "not a url at all",
            ""
        ]
        for input in inputs {
            let once = AppSettings.strippedBaseURL(input)
            let twice = AppSettings.strippedBaseURL(once)
            #expect(once == twice)
        }
    }

    @Test func exportSnapshotNeverContainsBaseURLCredentials() throws {
        let env = try makeEnv()
        env.settings.cloudLLMBaseURL = "https://user:pass@api.example.com/v1"
        let data = try JSONSerialization.data(withJSONObject: env.settings.exportableSettingsSnapshot())
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(!raw.contains("user:pass"))
    }

    // MARK: - Absent LLM fields resolve from the RESTORED provider, not a hardcoded one (Codex finding: cross-provider mix)

    @Test func v2RestoresOllamaProviderDefaultsWhenBaseURLAndModelAreAbsent() async throws {
        let env = try makeEnv()
        // Live state before restore starts on the OTHER provider, with Anthropic-shaped values —
        // if the absent-field default were still hardcoded to Anthropic, this would be
        // indistinguishable from a correct restore, so start from a neutral/different baseline.
        env.settings.llmProvider = .anthropic
        env.settings.cloudLLMBaseURL = "https://api.anthropic.com/v1"
        env.settings.cloudLLMModel = "claude-sonnet-4-5"

        let data = try json(v2Payload(settings: ["llmProvider": "ollama"]))
        _ = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)

        #expect(env.settings.llmProvider == .ollama)
        #expect(env.settings.cloudLLMBaseURL == "https://ollama.com/v1")
        #expect(env.settings.cloudLLMModel == "gpt-oss:120b")
    }

    @Test func v2RestoresAnthropicProviderDefaultsWhenBaseURLAndModelAreAbsent() async throws {
        let env = try makeEnv()
        env.settings.llmProvider = .ollama
        env.settings.cloudLLMBaseURL = "https://ollama.com/v1"
        env.settings.cloudLLMModel = "gpt-oss:120b"

        let data = try json(v2Payload(settings: ["llmProvider": "anthropic"]))
        _ = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)

        #expect(env.settings.llmProvider == .anthropic)
        #expect(env.settings.cloudLLMBaseURL == "https://api.anthropic.com/v1")
        #expect(env.settings.cloudLLMModel == "claude-sonnet-4-5")
    }

    @Test func v2RestoresOpenAICompatibleProviderHasNoKnownDefaultSoFieldsClearToEmpty() async throws {
        // openAICompatible has no known (baseURL, model) default — an absent field must resolve
        // to empty, never silently inherit whatever the previous provider had configured.
        let env = try makeEnv()
        env.settings.llmProvider = .anthropic
        env.settings.cloudLLMBaseURL = "https://api.anthropic.com/v1"
        env.settings.cloudLLMModel = "claude-sonnet-4-5"

        let data = try json(v2Payload(settings: ["llmProvider": "openAICompatible"]))
        _ = try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)

        #expect(env.settings.llmProvider == .openAICompatible)
        #expect(env.settings.cloudLLMBaseURL == "")
        #expect(env.settings.cloudLLMModel == "")
    }

    @Test func rejectsUnknownCloudSTTProvider() async throws {
        let env = try makeEnv()
        let data = try json(v2Payload(settings: ["cloudSTTProvider": "anthropic"]))

        await #expect(throws: BackupBundleError.invalidSettingsValue(key: AppSettings.Keys.cloudSTTProvider)) {
            try await BackupBundle.restore(data: data, settings: env.settings, templateStore: env.templateStore, snippetStore: env.snippetStore)
        }
    }

    // MARK: - Full round-trip over the current key set (PLAN.md F1.9: run now, batch-final gate later)

    @Test func fullRoundTripPreservesEveryExportableSetting() async throws {
        let envA = try makeEnv()
        let settingsA = envA.settings
        settingsA.hotKeySpec = HotKeySpec(modifiers: 0x0001, keyCode: nil)
        settingsA.insertLastDictationHotKeySpec = HotKeySpec(modifiers: 0, keyCode: 2)
        settingsA.voiceEditHotKeySpec = HotKeySpec(modifiers: 0, keyCode: 3)
        settingsA.historyPanelHotKeySpec = HotKeySpec(modifiers: 0, keyCode: 4)
        settingsA.sttEngine = .cloud
        settingsA.cloudSTTProvider = .openAICompatible
        settingsA.cloudSTTBaseURL = "https://user:pass@api.example.com/v1"
        settingsA.cloudSTTModel = "custom-transcription-model"
        settingsA.setWhisperModelFromUser("openai_whisper-tiny")
        settingsA.livePreviewEnabled = false
        settingsA.noiseSuppressionEnabled = false
        settingsA.edgeLauncherEnabled = true
        settingsA.edgeLauncherEdge = .left
        settingsA.edgeLauncherPosition = 0.25
        settingsA.launcherPanelPosition = NormalizedWindowPosition(displayID: "disp1", x: 0.1, y: 0.2)
        settingsA.recordingHUDPosition = NormalizedWindowPosition(displayID: "disp2", x: 0.3, y: 0.4)
        settingsA.transientHUDPosition = NormalizedWindowPosition(displayID: "disp3", x: 0.5, y: 0.6)
        settingsA.llmProvider = .ollama
        settingsA.cloudLLMBaseURL = "https://custom.example.com/v2"
        settingsA.cloudLLMModel = "custom-model"
        settingsA.activeTemplateID = "email"
        settingsA.recoveryRetention = .thirtyDays
        settingsA.mediaImportRetention = .never
        settingsA.localContextScope = .selectedText
        settingsA.automaticStyleEnabled = true
        settingsA.handsFreeMaxMinutes = 12
        settingsA.appRules = ["com.example.foo": "email"]
        settingsA.languagePin = "en"
        settingsA.defaultOutputLanguage = .spanish
        settingsA.appLanguageRules = ["com.example.bar": "pt"]
        // A superset of "en"/"pt" (not just the default pair) so this exercises the actual F5
        // key while keeping `languagePin`/`appLanguageRules` above meaningful — a set that
        // excluded either would eagerly coerce them away before export ever runs, and the
        // round-trip would pass vacuously (both sides coerced identically) rather than actually
        // testing the new key. See PLAN.md F1.9/F5.1.
        settingsA.dictationLanguages = ["en", "pt", "es"]
        settingsA.microphoneDeviceUID = "some-uid"
        settingsA.vocabularyText = "Kubernetes\nPostgres"

        let data = try await BackupBundle.export(settings: settingsA, templateStore: envA.templateStore, snippetStore: envA.snippetStore)

        let envB = try makeEnv()
        _ = try await BackupBundle.restore(data: data, settings: envB.settings, templateStore: envB.templateStore, snippetStore: envB.snippetStore)

        // Guard against a self-referential round-trip: comparing snapshotA to snapshotB alone
        // can't catch a key silently dropped from `exportableSettingsSnapshot()` on BOTH sides
        // (export would omit it and restore would reset it, yet the two snapshots would still
        // match). Tie snapshot completeness to `exportableKeys`, the canonical key list v1
        // export already iterates, so a future one-line addition to `exportableKeys` (F3/F5)
        // that forgets the snapshot case fails here instead of passing silently.
        #expect(Set(settingsA.exportableSettingsSnapshot().keys) == Set(AppSettings.exportableKeys))

        let snapshotA = try normalizedJSON(settingsA.exportableSettingsSnapshot())
        let snapshotB = try normalizedJSON(envB.settings.exportableSettingsSnapshot())
        #expect(snapshotA == snapshotB)
    }

    // MARK: - Helpers

    private struct Env {
        let settings: AppSettings
        let templateStore: TemplateStore
        let snippetStore: SnippetStore
    }

    private func makeEnv() throws -> Env {
        let suite = "BackupBundleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let templatesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        let snippetsDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        return Env(
            settings: AppSettings(defaults: defaults),
            templateStore: TemplateStore(fileURL: templatesDirectory.appendingPathComponent("templates.json")),
            snippetStore: try SnippetStore(databaseURL: snippetsDatabaseURL)
        )
    }

    private func v2Payload(settings: [String: Any] = [:], templates: [[String: Any]] = [], snippets: [[String: Any]] = []) -> [String: Any] {
        ["app": "FreeTalker", "formatVersion": 2, "settings": settings, "templates": templates, "snippets": snippets]
    }

    private func encodeArray<T: Encodable>(_ items: [T]) throws -> [[String: Any]] {
        try items.map { item in
            let data = try JSONEncoder().encode(item)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    private func json(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed])
    }

    private func normalizedJSON(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }
}
