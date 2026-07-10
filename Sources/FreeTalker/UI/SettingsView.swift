import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            TemplatesSettingsView()
                .tabItem { Label("Templates", systemImage: "text.badge.checkmark") }
        }
        .padding(20)
        // A SINGLE frame call with both min and max: chaining `.frame(maxWidth: .infinity, ...)`
        // followed by a separate `.frame(minWidth: 520, ...)` (the previous, insufficient fix)
        // makes the second call the outermost layout container SwiftUI proposes the window's
        // size to — and since that second call has no maxWidth/maxHeight of its own, it reports
        // its *ideal* (roughly minimum) size upward, discarding the first call's "fill available
        // space" entirely. The window itself still resizes/maximizes fine (that's a property of
        // the Window scene, not this view), but the content stops tracking it. One call with
        // min *and* max keeps both constraints on the same flexible frame.
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var templateStore = TemplateStore.shared
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()
    @State private var microphoneAuthorized = Permissions.isMicrophoneAuthorized()
    @State private var inputMonitoringAuthorized = Permissions.isInputMonitoringAuthorized()
    @State private var capturingHotKey = false
    @State private var captureSession: HotKeyCapture.Session?
    /// Set when re-recording the PTT key is refused because it would collide with, or
    /// shadow-engage before, the bound Redo Last key. See HotKeySpec.swift constraint helpers.
    @State private var hotKeyRecorderMessage: String?
    @State private var capturingRedoHotKey = false
    @State private var redoCaptureSession: HotKeyCapture.Session?
    /// Set when a captured Redo Last spec is refused (modifier-only, collides with, or is
    /// shadowed by, the PTT key). See PLAN.md step 9.
    @State private var redoRecorderMessage: String?
    @State private var inputDevices: [AudioInputDevices.Device] = []
    @State private var runningApps: [NSRunningApplication] = []
    @State private var newRuleBundleID: String?
    @State private var newRuleTemplateID: String?

    @State private var cloudSTTKey = Keychain.get(account: Keychain.Account.cloudSTTKey) ?? ""
    @State private var cloudLLMKey = Keychain.get(account: Keychain.Account.cloudLLMKey(for: AppSettings.shared.llmProvider)) ?? ""
    // Set when Keychain.set(_:account:) returns false, so the UI never claims a key was saved
    // when it wasn't. The field itself is left as typed so the user can retry. See Round 2
    // Codex finding 7.
    @State private var cloudSTTKeyError = false
    @State private var cloudLLMKeyError = false

    // "Test connection" (Task 3): in-flight flag gates the button + shows a ProgressView;
    // result holds only the fixed, already-classified message from `ConnectionTestOutcome` —
    // never a raw response body or the key. See ConnectionTest.swift.
    @State private var cloudSTTTesting = false
    @State private var cloudSTTTestResult: String?
    @State private var cloudLLMTesting = false
    @State private var cloudLLMTestResult: String?

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Circle()
                        .fill(accessibilityTrusted ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(accessibilityTrusted ? "Accessibility granted" : "Accessibility not granted")
                    Spacer()
                    if !accessibilityTrusted {
                        Button("Open System Settings") { Permissions.openAccessibilitySettings() }
                    }
                }
                HStack {
                    Circle()
                        .fill(microphoneAuthorized ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(microphoneAuthorized ? "Microphone granted" : "Microphone not granted")
                    Spacer()
                    if !microphoneAuthorized {
                        Button("Request") {
                            Permissions.requestMicrophoneAccess { granted in
                                DispatchQueue.main.async { microphoneAuthorized = granted }
                            }
                        }
                        Button("Open System Settings") { Permissions.openMicrophoneSettings() }
                    }
                }

                HStack {
                    Circle()
                        .fill(inputMonitoringAuthorized ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(inputMonitoringAuthorized ? "Input Monitoring granted" : "Input Monitoring not granted")
                    Spacer()
                    if !inputMonitoringAuthorized {
                        Button("Open System Settings") { Permissions.openInputMonitoringSettings() }
                    }
                }
            }

            Section("Push-to-talk key") {
                HStack {
                    Text("Hold key: \(settings.hotKeySpec.displayLabel)")
                    Spacer()
                    Button(capturingHotKey ? "Press a key or combination… (⎋ cancels)" : "Change…") {
                        beginCapture()
                    }
                    .disabled(capturingHotKey)
                }
                if let hotKeyStatusText = coordinator.hotKeyStatusText {
                    Text("⚠️ \(hotKeyStatusText)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let hotKeyRecorderMessage {
                    Text(hotKeyRecorderMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Text("Redo-last key: \(settings.redoHotKeySpec?.displayLabel ?? "Unbound")")
                    Spacer()
                    Button("Clear") {
                        // AppCoordinator re-plumbs the tap itself on any hotKeySpec/redoHotKeySpec
                        // change (see its Combine subscriptions) — no manual call needed here.
                        settings.redoHotKeySpec = nil
                        redoRecorderMessage = nil
                    }
                    .disabled(settings.redoHotKeySpec == nil)
                    Button(capturingRedoHotKey ? "Press a key or combination… (⎋ cancels)" : "Change…") {
                        beginRedoCapture()
                    }
                    .disabled(capturingRedoHotKey)
                }
                Text("Re-inserts your latest dictation at the cursor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let redoRecorderMessage {
                    Text(redoRecorderMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Hands-free recording") {
                Stepper(value: $settings.handsFreeMaxMinutes, in: 1...60) {
                    Text("Auto-stop after \(settings.handsFreeMaxMinutes) minute\(settings.handsFreeMaxMinutes == 1 ? "" : "s")")
                }
                Text("Tap the push-to-talk key to start a hands-free recording that keeps going until you tap it again, click the HUD pill, or press Esc to cancel. Holding the key down instead is classic push-to-talk (unbounded, released to stop).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input device", selection: $settings.microphoneDeviceUID) {
                    Text("System default").tag(nil as String?)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
                Button("Refresh device list") { inputDevices = AudioInputDevices.enumerate() }
                    .font(.caption)
            }

            Section("Transcription engine") {
                Picker("Engine", selection: $settings.sttEngine) {
                    Text("WhisperKit (on-device)").tag(STTEngineKind.whisperKit)
                    Text("Cloud (BYOK)").tag(STTEngineKind.cloud)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.sttEngine) { _, newValue in
                    if newValue == .whisperKit {
                        Task { await coordinator.whisperEngine.preload() }
                    }
                }

                Text(coordinator.engineStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Live preview while recording", isOn: $settings.livePreviewEnabled)
                if settings.sttEngine == .cloud && !coordinator.whisperEngine.isLoaded {
                    Text("Cloud STT is active and the on-device model isn't loaded, so preview is disabled (avoids per-chunk cloud uploads).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.sttEngine == .cloud {
                    TextField("Base URL", text: $settings.cloudSTTBaseURL)
                    SecureField("API key", text: $cloudSTTKey)
                        .onChange(of: cloudSTTKey) { _, newValue in
                            cloudSTTKeyError = !Keychain.set(newValue, account: Keychain.Account.cloudSTTKey)
                        }
                    if cloudSTTKeyError {
                        Text("Failed to save key to Keychain")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button("Test connection") { testCloudSTTConnection() }
                            .disabled(cloudSTTTesting || !AppCoordinator.isCloudSTTConfigured(baseURL: settings.cloudSTTBaseURL, key: cloudSTTKey))
                        if cloudSTTTesting {
                            ProgressView().controlSize(.small)
                        } else if let cloudSTTTestResult {
                            Text(cloudSTTTestResult)
                                .font(.caption)
                                .foregroundStyle(cloudSTTTestResult.hasSuffix("Connected ✓") ? .green : .red)
                        }
                    }
                }
            }

            Section("Cloud post-processing (BYOK)") {
                Picker("Provider", selection: $settings.llmProvider) {
                    Text("Anthropic").tag(LLMProviderKind.anthropic)
                    Text("Ollama").tag(LLMProviderKind.ollama)
                    Text("OpenAI-compatible").tag(LLMProviderKind.openAICompatible)
                }
                .onChange(of: settings.llmProvider) { _, newProvider in
                    // The API key field is Keychain-backed (not part of `AppSettings`), so it
                    // has to be reloaded explicitly for the newly selected provider's scoped
                    // account — otherwise it would keep showing the previous provider's key.
                    // See PLAN.md step 5.
                    cloudLLMKey = Keychain.get(account: Keychain.Account.cloudLLMKey(for: newProvider)) ?? ""
                    cloudLLMKeyError = false
                }
                TextField("Base URL", text: $settings.cloudLLMBaseURL, prompt: providerDefaultBaseURL.map(Text.init))
                TextField("Model", text: $settings.cloudLLMModel, prompt: providerDefaultModel.map(Text.init))
                SecureField("API key", text: $cloudLLMKey)
                    .onChange(of: cloudLLMKey) { _, newValue in
                        cloudLLMKeyError = !Keychain.set(newValue, account: Keychain.Account.cloudLLMKey(for: settings.llmProvider))
                    }
                if cloudLLMKeyError {
                    Text("Failed to save key to Keychain")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Test connection") { testCloudLLMConnection() }
                        .disabled(cloudLLMTesting || !AppCoordinator.isCloudLLMConfigured(snapshot: settings.cloudLLMSnapshot))
                    if cloudLLMTesting {
                        ProgressView().controlSize(.small)
                    } else if let cloudLLMTestResult {
                        Text(cloudLLMTestResult)
                            .font(.caption)
                            .foregroundStyle(cloudLLMTestResult.hasSuffix("Connected ✓") ? .green : .red)
                    }
                }
                Text("Used for all templates whenever provider, model, and API key are configured. Clear the key to go back to on-device processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vocabulary") {
                Text("One term per line — proper nouns, names, or jargon that should be recognized and spelled correctly. Used to bias transcription and post-processing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.vocabularyText)
                    .frame(minHeight: 100)
                if let truncation = settings.vocabularyTruncation {
                    Text("Using first \(truncation.kept) of \(truncation.total) terms (limit: \(AppSettings.maxVocabularyTerms) terms / \(AppSettings.maxVocabularyCharacterBudget) characters).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("App Rules") {
                Text("Automatically use a specific Template when dictating into a chosen app, instead of the Active Template.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(settings.appRules.keys.sorted(), id: \.self) { bundleID in
                    HStack {
                        Text(displayName(forBundleID: bundleID))
                        Spacer()
                        Text(templateStore.template(id: settings.appRules[bundleID] ?? "")?.name ?? "Unknown Template")
                            .foregroundStyle(.secondary)
                        Button {
                            settings.appRules.removeValue(forKey: bundleID)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Picker("App", selection: $newRuleBundleID) {
                        Text("Choose an app").tag(nil as String?)
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown").tag(app.bundleIdentifier)
                        }
                    }
                    Picker("Template", selection: $newRuleTemplateID) {
                        Text("Choose a template").tag(nil as String?)
                        ForEach(templateStore.templates) { template in
                            Text(template.name).tag(template.id as String?)
                        }
                    }
                    Button("Add") {
                        guard let newRuleBundleID, let newRuleTemplateID else { return }
                        settings.appRules[newRuleBundleID] = newRuleTemplateID
                        self.newRuleBundleID = nil
                        self.newRuleTemplateID = nil
                    }
                    .disabled(newRuleBundleID == nil || newRuleTemplateID == nil)
                }
                Button("Refresh app list") { runningApps = Self.enumerateRunningApps() }
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            inputDevices = AudioInputDevices.enumerate()
            runningApps = Self.enumerateRunningApps()
        }
        .onReceive(refreshTimer) { _ in
            accessibilityTrusted = Permissions.isAccessibilityTrusted()
            microphoneAuthorized = Permissions.isMicrophoneAuthorized()
            inputMonitoringAuthorized = Permissions.isInputMonitoringAuthorized()
        }
    }

    /// Running, user-facing (`.regular` activation policy — excludes menu-bar-only/background
    /// agents) apps, sorted by name, for the App Rules "App" picker. See PLAN 2 "Settings UI".
    private static func enumerateRunningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// Best-effort display name for an existing rule's bundle id: the running app's name if
    /// still running, else the bundle id itself (no new API surface just to resolve a name for
    /// an app that isn't running — see ponytail).
    private func displayName(forBundleID bundleID: String) -> String {
        runningApps.first(where: { $0.bundleIdentifier == bundleID })?.localizedName ?? bundleID
    }

    /// Shown as the Base URL/Model fields' placeholder for the active provider, when it has a
    /// known default — nil (no placeholder) for `openAICompatible`. See PLAN.md step 5.
    private var providerDefaultBaseURL: String? { AppSettings.knownProviderDefaults[settings.llmProvider]?.baseURL }
    private var providerDefaultModel: String? { AppSettings.knownProviderDefaults[settings.llmProvider]?.model }

    private func beginCapture() {
        capturingHotKey = true
        // FreeTalker is LSUIElement (no Dock icon), so opening the Settings window from the
        // menu bar does not reliably make it key/active — and a local NSEvent monitor only
        // fires for events routed to a key window. Force both explicitly so capture is not
        // silently a no-op. See root cause B.
        NSApp.activate()
        NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
        let session = HotKeyCapture.Session()
        captureSession = session
        session.start { spec in
            defer {
                capturingHotKey = false
                captureSession = nil
            }
            guard let spec else { return } // Escape cancelled the capture.
            // Refuse a PTT reassignment that would newly shadow the bound Redo Last key (PLAN.md
            // step 9, "both directions") — or collide with it outright.
            if let redo = settings.redoHotKeySpec {
                if HotKeySpec.collides(spec, redo) {
                    hotKeyRecorderMessage = "Same as the Redo-last key — pick a different chord."
                    return
                }
                if HotKeySpec.redoShadowsHeldPTT(pttSpec: spec, redoSpec: redo) {
                    hotKeyRecorderMessage = "Would trigger before the Redo-last key — pick a different chord."
                    return
                }
            }
            hotKeyRecorderMessage = nil
            // AppCoordinator re-plumbs the tap itself on any hotKeySpec/redoHotKeySpec change
            // (see its Combine subscriptions) — no manual call needed here.
            settings.hotKeySpec = spec
        }
    }

    /// Captures a spec for the optional Redo Last key, applying the recorder-level constraints
    /// from PLAN.md step 9 before accepting it: must end in a real key (not modifier-only), must
    /// not collide with the PTT key, and must not be shadow-engaged by holding the PTT key's
    /// modifiers en route to it. See CONTEXT.md "Redo Last".
    private func beginRedoCapture() {
        capturingRedoHotKey = true
        NSApp.activate()
        NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
        let session = HotKeyCapture.Session()
        redoCaptureSession = session
        session.start { spec in
            defer {
                capturingRedoHotKey = false
                redoCaptureSession = nil
            }
            guard let spec else { return } // Escape cancelled the capture.
            guard HotKeySpec.isValidRedoSpec(spec) else {
                redoRecorderMessage = "Redo needs a key, not just modifiers."
                return
            }
            guard !HotKeySpec.collides(spec, settings.hotKeySpec) else {
                redoRecorderMessage = "Same as the push-to-talk key — pick a different chord."
                return
            }
            guard !HotKeySpec.redoShadowsHeldPTT(pttSpec: settings.hotKeySpec, redoSpec: spec) else {
                redoRecorderMessage = "Would trigger push-to-talk before this key — pick a different chord."
                return
            }
            redoRecorderMessage = nil
            // AppCoordinator re-plumbs the tap itself on any hotKeySpec/redoHotKeySpec change
            // (see its Combine subscriptions) — no manual call needed here.
            settings.redoHotKeySpec = spec
        }
    }

    /// "Test connection" for the Cloud STT (BYOK) section. Snapshots the base URL/key into
    /// locals before the `await` so a mid-flight edit to the fields can't retroactively change
    /// what's being tested. `ConnectionTestOutcome.message` is the only thing ever assigned to
    /// `cloudSTTTestResult` — never the thrown error's description, which could carry a response
    /// body. See Task 3 security requirement.
    private func testCloudSTTConnection() {
        cloudSTTTesting = true
        cloudSTTTestResult = nil
        let baseURL = settings.cloudSTTBaseURL
        let key = cloudSTTKey
        Task {
            let outcome: ConnectionTestOutcome
            do {
                let status = try await CloudSTTEngine.testConnection(baseURL: baseURL, apiKey: key)
                outcome = .fromStatusCode(status)
            } catch {
                outcome = .fromTransportError(error)
            }
            cloudSTTTesting = false
            cloudSTTTestResult = "Cloud STT: \(outcome.message)"
        }
    }

    /// "Test connection" for the Cloud post-processing (BYOK) section. Same snapshot-before-await
    /// discipline as `testCloudSTTConnection`, via `AppSettings.cloudLLMSnapshot` — the same
    /// snapshot type `CloudLLMProcessor.process` (the real dictation path) and
    /// `AppCoordinator.isCloudLLMConfigured` (this button's `.disabled` gate) both use, so all
    /// three can never disagree about what's being tested. See CloudLLMSettingsSnapshot's doc
    /// comment.
    private func testCloudLLMConnection() {
        cloudLLMTesting = true
        cloudLLMTestResult = nil
        let processor = CloudLLMProcessor(snapshot: settings.cloudLLMSnapshot)
        let providerLabel = settings.llmProvider.rawValue
        Task {
            let outcome: ConnectionTestOutcome
            do {
                let status = try await processor.testConnection()
                outcome = .fromStatusCode(status)
            } catch {
                outcome = .fromTransportError(error)
            }
            cloudLLMTesting = false
            cloudLLMTestResult = "\(providerLabel): \(outcome.message)"
        }
    }
}

private struct TemplatesSettingsView: View {
    @ObservedObject private var store = TemplateStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedID: String?

    var body: some View {
        HSplitView {
            List(selection: $selectedID) {
                ForEach(store.templates) { template in
                    HStack {
                        Text(template.name)
                        if template.id == settings.activeTemplateID {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .tag(template.id)
                }
            }
            // Master list stays compact — a bounded maxWidth so it doesn't compete for space
            // with the (flexible) detail editor. Previously this had no maxWidth at all, and
            // since List is inherently greedy (defaults to filling all available width when
            // unconstrained) while the old Form-based TemplateEditor reported a small ideal
            // width, HSplitView handed nearly all the window's width to this list and squeezed
            // the editor down to its minimum — exactly the reported "list occupies almost the
            // whole screen, prompt editor is shrunk" bug.
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        let new = Template(id: UUID().uuidString, name: "New Template", prompt: "")
                        store.upsert(new)
                        selectedID = new.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let selectedID { store.delete(id: selectedID); self.selectedID = nil }
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                }
            }

            if let selectedID, let template = store.template(id: selectedID) {
                TemplateEditor(template: template)
                    .id(template.id)
            } else {
                Text("Select a template").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct TemplateEditor: View {
    @State var template: Template
    @ObservedObject private var store = TemplateStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // A plain VStack, not a Form: Form/List lay out as a scrollable stack of rows sized to
        // their own content, so a `maxHeight: .infinity` TextEditor row inside one does not
        // reliably claim the Form's leftover vertical space. A VStack of fixed-height header
        // rows plus one flexible child (the TextEditor, `maxHeight: .infinity`) is the standard
        // pattern for "everything else stays compact, this one view eats the rest" and is what
        // makes the prompt editor grow with the window per Task 2.
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $template.name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: template.name) { _, _ in store.upsert(template) }
            Button(template.id == settings.activeTemplateID ? "Active Template" : "Make Active") {
                settings.activeTemplateID = template.id
            }
            .disabled(template.id == settings.activeTemplateID)

            Text("Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $template.prompt)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                .onChange(of: template.prompt) { _, _ in store.upsert(template) }
        }
        .padding()
    }
}
