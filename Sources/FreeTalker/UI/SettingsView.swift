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
        .frame(width: 520, height: 480)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = AppCoordinator.shared
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()
    @State private var microphoneAuthorized = Permissions.isMicrophoneAuthorized()
    @State private var inputMonitoringAuthorized = Permissions.isInputMonitoringAuthorized()
    @State private var capturingHotKey = false
    @State private var captureSession: HotKeyCapture.Session?
    @State private var inputDevices: [AudioInputDevices.Device] = []

    @State private var cloudSTTKey = Keychain.get(account: Keychain.Account.cloudSTTKey) ?? ""
    @State private var cloudLLMKey = Keychain.get(account: Keychain.Account.cloudLLMKey) ?? ""
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
                    Text("OpenAI-compatible").tag(LLMProviderKind.openAICompatible)
                }
                TextField("Base URL", text: $settings.cloudLLMBaseURL)
                TextField("Model", text: $settings.cloudLLMModel)
                SecureField("API key", text: $cloudLLMKey)
                    .onChange(of: cloudLLMKey) { _, newValue in
                        cloudLLMKeyError = !Keychain.set(newValue, account: Keychain.Account.cloudLLMKey)
                    }
                if cloudLLMKeyError {
                    Text("Failed to save key to Keychain")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Only used by Templates with \"Use cloud model\" enabled.")
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
        }
        .formStyle(.grouped)
        .onAppear { inputDevices = AudioInputDevices.enumerate() }
        .onReceive(refreshTimer) { _ in
            accessibilityTrusted = Permissions.isAccessibilityTrusted()
            microphoneAuthorized = Permissions.isMicrophoneAuthorized()
            inputMonitoringAuthorized = Permissions.isInputMonitoringAuthorized()
        }
    }

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
            if let spec {
                settings.hotKeySpec = spec
                AppCoordinator.shared.restartHotKeyListening()
            }
            capturingHotKey = false
            captureSession = nil
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
                        let new = Template(id: UUID().uuidString, name: "New Template", prompt: "", useCloud: false)
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
            Toggle("Use cloud model", isOn: $template.useCloud)
                .onChange(of: template.useCloud) { _, _ in store.upsert(template) }
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
