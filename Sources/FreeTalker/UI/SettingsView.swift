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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 480)
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
                        settings.redoHotKeySpec = nil
                        redoRecorderMessage = nil
                        AppCoordinator.shared.restartHotKeyListening()
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
            settings.hotKeySpec = spec
            AppCoordinator.shared.restartHotKeyListening()
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
            settings.redoHotKeySpec = spec
            AppCoordinator.shared.restartHotKeyListening()
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
            .frame(minWidth: 160)
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
        Form {
            TextField("Name", text: $template.name)
                .onChange(of: template.name) { _, _ in store.upsert(template) }
            Button(template.id == settings.activeTemplateID ? "Active Template" : "Make Active") {
                settings.activeTemplateID = template.id
            }
            .disabled(template.id == settings.activeTemplateID)

            Text("Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $template.prompt)
                .frame(minHeight: 200)
                .onChange(of: template.prompt) { _, _ in store.upsert(template) }
        }
        .padding()
    }
}
