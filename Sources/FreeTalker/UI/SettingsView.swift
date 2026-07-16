import AppKit
import SwiftUI

struct SpeechModelRowPresentation: Equatable {
    enum Action: Equatable { case none, download, delete }

    let status: String
    let canSelect: Bool
    let canDelete: Bool
    let action: Action
    let actionCaption: String?
    let actionEnabled: Bool

    @MainActor static func make(
        state: SpeechModelStore.State,
        selected: Bool,
        activeDownloadVariant: String?
    ) -> Self {
        let unsupported = !state.supported
        let canSelect = state.phase == .downloaded && !state.active && !selected && !unsupported
        let canDelete = !selected && SpeechModelStore.canDelete(phase: state.phase, active: state.active)
        let status: String
        if state.active {
            if unsupported {
                status = "Active — unsupported on this Mac"
            } else if case .notDownloaded = state.phase {
                status = "Active — downloads on first use"
            } else {
                status = phaseText(state.phase, active: true)
            }
        } else if selected {
            if case .busy = state.phase {
                status = "Selected — pending reload · \(phaseText(state.phase, active: false))"
            } else {
                status = "Selected — pending reload"
            }
        } else if unsupported {
            status = "Unsupported on this Mac"
        } else {
            status = phaseText(state.phase, active: false)
        }

        if canDelete {
            return Self(status: status, canSelect: canSelect, canDelete: true,
                        action: .delete, actionCaption: nil, actionEnabled: true)
        }
        if SpeechModelStore.canStartManualDownload(phase: state.phase, reserved: false),
           !state.active, !unsupported {
            let waiting = activeDownloadVariant != nil
            return Self(status: status, canSelect: canSelect, canDelete: false,
                        action: .download,
                        actionCaption: waiting ? "waiting for current download" : nil,
                        actionEnabled: !waiting)
        }
        return Self(status: status, canSelect: canSelect, canDelete: false,
                    action: .none, actionCaption: nil, actionEnabled: false)
    }

    private static func phaseText(_ phase: SpeechModelStore.Phase, active: Bool) -> String {
        switch phase {
        case .notDownloaded: return "Not downloaded"
        case .downloading(let progress): return "Downloading \(Int(progress * 100))%"
        case .downloaded: return active ? "Active" : "Downloaded"
        case .failed(let hint): return "Failed — \(hint)"
        case .busy(let target):
            let name = SpeechModelCatalog.entry(for: target)?.displayName ?? target
            return "Loading \(name)…"
        }
    }

    static func radioAccessibilityLabel(displayName: String, active: Bool, selected: Bool) -> String {
        if active { return "\(displayName), active" }
        if selected { return "\(displayName), selected — pending reload" }
        return "\(displayName), not selected"
    }
}

enum SpeechModelDeleteFailure {
    static func message(modelName: String, hint: String) -> String {
        "Couldn't delete \(modelName): \(hint)"
    }
}

struct SettingsView: View {
    static let automaticTemplateHelp = "When no App Rule matches, FreeTalker chooses Email, Refined Message, Clean Dictation, or Refined Prompt. Turn this off to keep the Active Template."

    @ObservedObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var navigator = SettingsNavigator.shared
    @State private var selection: SettingsDestination

    /// Seeds the initial tab from `SettingsNavigator.shared.pendingDestination` so a caller that
    /// sets it before opening the "settings" window scene lands directly on that tab, with no
    /// flash of the default Privacy tab first. `.onChange` below handles the case where the
    /// window is already open and someone re-navigates it.
    init() {
        _selection = State(initialValue: SettingsNavigator.shared.pendingDestination ?? .privacy)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
            Divider()
            ZStack {
                GeneralSettingsView(destination: selection)
                    .opacity(selection.isSettingsPage ? 1 : 0)
                    .allowsHitTesting(selection.isSettingsPage)
                    .disabled(!selection.isSettingsPage)
                    .accessibilityHidden(!selection.isSettingsPage)

                TemplatesSettingsView()
                    .opacity(selection == .templates ? 1 : 0)
                    .allowsHitTesting(selection == .templates)
                    .disabled(selection != .templates)
                    .accessibilityHidden(selection != .templates)

                SnippetsSettingsView(
                    store: coordinator.snippetStore,
                    initializationError: coordinator.snippetStoreInitializationError,
                    retry: { coordinator.retrySnippetStoreInitialization() }
                )
                .opacity(selection == .snippets ? 1 : 0)
                .allowsHitTesting(selection == .snippets)
                .disabled(selection != .snippets)
                .accessibilityHidden(selection != .snippets)

                SettingsEditorPage(title: "Library", subtitle: "Browse, translate, and delete past dictations") {
                    LibraryView()
                }
                .opacity(selection == .library ? 1 : 0)
                .allowsHitTesting(selection == .library)
                .disabled(selection != .library)
                .accessibilityHidden(selection != .library)
            }
        }
        .frame(minWidth: 780, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .onAppear { navigator.pendingDestination = nil }
        .onChange(of: navigator.pendingDestination) { _, newValue in
            guard let newValue else { return }
            selection = newValue
            navigator.pendingDestination = nil
        }
    }
}

private extension SettingsDestination {
    var isSettingsPage: Bool {
        switch self {
        case .privacy, .recording, .transcription, .processing, .launcher, .storage:
            true
        case .templates, .snippets, .library:
            false
        }
    }
}

struct OutputLanguageSettingsPresentation: Equatable, Sendable {
    let translationAvailability: CloudFeatureAvailability

    var tooltip: String? { translationAvailability.tooltip }
    var accessibilityHelp: String? { translationAvailability.accessibilityHelp }
    var privacyDisclosure: String { CloudPrivacyDisclosure.liveOutputTranslation }

    static func make(snapshot: CloudLLMSettingsSnapshot) -> Self {
        Self(translationAvailability: .make(
            eligibility: snapshot.eligibility,
            provider: snapshot.provider
        ))
    }

    func isEnabled(_ language: OutputLanguage) -> Bool {
        language == .sameAsSpoken || translationAvailability.enabled
    }
}

struct VoiceEditHotKeyPresentation: Equatable {
    let label: String
    let actionLabel: String

    static func make(spec: HotKeySpec?, capturing: Bool) -> Self {
        Self(
            label: "Voice Edit key: \(spec?.displayLabel ?? "Unbound")",
            actionLabel: capturing ? "Press a key or combination… (⎋ cancels)" : "Change…"
        )
    }
}

struct ScreenRecordingPermissionPresentation: Equatable {
    let label: String
    let guidance: String?
    let showsRequestAccess: Bool
    let showsOpenSystemSettings: Bool

    static func make(status: ScreenRecordingAuthorization, requestAttempted: Bool) -> Self {
        let granted = status == .granted
        return Self(
            label: granted ? "Screen Recording granted" : (requestAttempted ? "Screen Recording not available yet" : "Screen Recording not granted"),
            guidance: !granted && requestAttempted
                ? "macOS may require FreeTalker to relaunch after access is granted. If it still appears unavailable, remove and re-add FreeTalker in System Settings."
                : nil,
            showsRequestAccess: !granted && !requestAttempted,
            showsOpenSystemSettings: !granted
        )
    }
}

struct InputMonitoringPermissionPresentation: Equatable {
    let isOperational: Bool
    let label: String
    let guidance: String
    let showsOpenSystemSettings: Bool

    static func make(rawAuthorized: Bool, hotKeyOperational: Bool) -> Self {
        if hotKeyOperational {
            return Self(
                isOperational: true,
                label: "Input Monitoring and global shortcuts working",
                guidance: "",
                showsOpenSystemSettings: false
            )
        }
        return Self(
            isOperational: false,
            label: rawAuthorized
                ? "Global shortcuts unavailable"
                : "Input Monitoring and global shortcuts unavailable",
            guidance: "Enable FreeTalker in System Settings, then relaunch it. If it is already enabled, remove and re-add it.",
            showsOpenSystemSettings: true
        )
    }
}

enum VocabularyEditorPresentation {
    static let placeholder = "One term or phrase per line"
    static let examples = ["OpenAI", "ScreenCaptureKit"]
    static let accessibilityLabel = "Vocabulary terms"
    static let minimumHeight: CGFloat = 100
    static let cornerRadius: CGFloat = 7
}

private struct VocabularyEditorField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(VocabularyEditorPresentation.placeholder)
                    ForEach(VocabularyEditorPresentation.examples,
                            id: \.self) { example in
                        Text(example)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.clear)
                .focused($isFocused)
                .accessibilityLabel(
                    VocabularyEditorPresentation.accessibilityLabel
                )
        }
        .frame(minHeight: VocabularyEditorPresentation.minimumHeight)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(
            cornerRadius: VocabularyEditorPresentation.cornerRadius
        ))
        .overlay {
            RoundedRectangle(
                cornerRadius: VocabularyEditorPresentation.cornerRadius
            )
            .stroke(
                isFocused ? Color.accentColor :
                    Color(nsColor: .separatorColor),
                lineWidth: isFocused ? 2 : 1
            )
        }
    }
}

private struct GeneralSettingsView: View {
    let destination: SettingsDestination
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var speechModelStore = AppCoordinator.shared.speechModelStore
    @ObservedObject private var templateStore = TemplateStore.shared
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()
    @State private var microphoneAuthorized = Permissions.isMicrophoneAuthorized()
    @State private var inputMonitoringAuthorized = Permissions.isInputMonitoringAuthorized()
    @State private var screenRecordingAuthorization = Permissions.screenRecordingAuthorization()
    @State private var screenRecordingRequestAttempted = false
    @State private var capturingHotKey = false
    @State private var captureSession: HotKeyCapture.Session?
    /// Set when re-recording the PTT key is refused because it would collide with, or
    /// shadow-engage before, the bound Insert Last Dictation key. See HotKeySpec.swift constraint
    /// helpers.
    @State private var hotKeyRecorderMessage: String?
    @State private var capturingInsertLastDictationHotKey = false
    @State private var insertLastDictationCaptureSession: HotKeyCapture.Session?
    @State private var insertLastDictationRecorderMessage: String?
    @State private var capturingVoiceEditHotKey = false
    @State private var voiceEditCaptureSession: HotKeyCapture.Session?
    @State private var voiceEditRecorderMessage: String?
    @State private var inputDevices: [AudioInputDevices.Device] = []
    @State private var runningApps: [NSRunningApplication] = []
    @State private var newRuleBundleID: String?
    @State private var newRuleTemplateID: String?
    @State private var newRuleLanguage: String?

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
    @State private var modelPendingDeletion: SpeechModelCatalogEntry?
    @State private var modelDeleteError: String?
    @State private var exportSettingsError: String?

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            settingsPage(
                .privacy,
                title: "Privacy",
                subtitle: "Permissions and on-device context"
            ) {
                permissionsCard
                SettingsCard(title: "Local privacy", subtitle: "Choose what on-device context FreeTalker may use") {
                    localContextSection
                }
            }

            settingsPage(
                .recording,
                title: "Recording",
                subtitle: "Configure dictation shortcuts and hands-free recording"
            ) {
                recordingCard
            }

            settingsPage(
                .transcription,
                title: "Transcription",
                subtitle: "Select audio input, speech recognition, and vocabulary preferences"
            ) {
                audioAndTranscriptionCard
            }

            settingsPage(
                .processing,
                title: "Context & Processing",
                subtitle: "Choose dictation context, automation, and cloud post-processing"
            ) {
                contextAndAutomationCard
                cloudProcessingCard
                SettingsCard(title: "Output language", subtitle: "Choose the language FreeTalker uses after processing") {
                    outputLanguagePicker
                        .padding(.vertical, 12)
                }
            }

            settingsPage(
                .launcher,
                title: "Launcher",
                subtitle: "Show a compact launcher at the edge of the screen"
            ) {
                floatingControlsCard
            }

            settingsPage(
                .storage,
                title: "Storage",
                subtitle: "Choose how long local recordings and imports are retained"
            ) {
                storageCard
            }
        }
        .confirmationDialog(
            "Delete \(modelPendingDeletion?.displayName ?? "speech model")?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { entry in
            Button("Delete model", role: .destructive) {
                modelPendingDeletion = nil
                Task {
                    do {
                        try await speechModelStore.delete(entry.id)
                    } catch {
                        modelDeleteError = SpeechModelDeleteFailure.message(
                            modelName: entry.displayName,
                            hint: error.localizedDescription
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { modelPendingDeletion = nil }
        } message: { entry in
            let bytes = speechModelStore.states[entry.id]?.sizeBytes ?? 0
            Text("This removes \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) from local storage.")
        }
        .alert(
            "Model deletion failed",
            isPresented: Binding(
                get: { modelDeleteError != nil },
                set: { if !$0 { modelDeleteError = nil } }
            )
        ) {
            Button("OK") { modelDeleteError = nil }
        } message: {
            Text(modelDeleteError ?? "The model couldn't be deleted.")
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { exportSettingsError != nil },
                set: { if !$0 { exportSettingsError = nil } }
            )
        ) {
            Button("OK") { exportSettingsError = nil }
        } message: {
            Text(exportSettingsError ?? "The settings couldn't be exported.")
        }
        .onAppear {
            inputDevices = AudioInputDevices.enumerate()
            runningApps = Self.enumerateRunningApps()
        }
        .onReceive(refreshTimer) { _ in
            accessibilityTrusted = Permissions.isAccessibilityTrusted()
            microphoneAuthorized = Permissions.isMicrophoneAuthorized()
            inputMonitoringAuthorized = Permissions.isInputMonitoringAuthorized()
            screenRecordingAuthorization = Permissions.screenRecordingAuthorization()
        }
    }

    private func settingsPage<Content: View>(
        _ page: SettingsDestination,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        SettingsPage(title: title, subtitle: subtitle, content: content)
            .opacity(destination == page ? 1 : 0)
            .allowsHitTesting(destination == page)
            .disabled(destination != page)
            .accessibilityHidden(destination != page)
    }

    @ViewBuilder
    private var permissionsCard: some View {
        SettingsCard(title: "Permissions", subtitle: "Allow FreeTalker to record and insert dictation") {
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
            .padding(.vertical, 8)
            Divider()
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
            .padding(.vertical, 8)
            Divider()
            HStack {
                Circle()
                    .fill(inputMonitoringPresentation.isOperational ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(inputMonitoringPresentation.label)
                Spacer()
                if inputMonitoringPresentation.showsOpenSystemSettings {
                    Button("Open System Settings") { Permissions.openInputMonitoringSettings() }
                }
            }
            .padding(.vertical, 8)
            if !inputMonitoringPresentation.isOperational {
                Text(inputMonitoringPresentation.guidance)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
            }
            Divider()
            HStack {
                Circle()
                    .fill(screenRecordingAuthorization == .granted ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(screenRecordingPermissionLabel)
                Spacer()
                if screenRecordingPresentation.showsRequestAccess {
                    Button("Request Access") {
                        screenRecordingRequestAttempted = true
                        screenRecordingAuthorization = Permissions.requestScreenRecording()
                    }
                }
                if screenRecordingPresentation.showsOpenSystemSettings {
                    Button("Open System Settings") { Permissions.openScreenRecordingSettings() }
                }
            }
            .padding(.vertical, 8)
            if let guidance = screenRecordingPresentation.guidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var contextAndAutomationCard: some View {
        SettingsCard(title: "Automation", subtitle: "How FreeTalker selects and applies dictation formats") {
            automaticTemplateSection
            Divider()
            appRulesSection
        }
    }

    @ViewBuilder
    private var localContextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Text context", selection: $settings.localContextScope) {
                    ForEach(LocalContextScope.allCases, id: \.rawValue) { scope in
                        Text(scope.displayName)
                            .help(scope.explanation)
                            .tag(scope)
                    }
                }
                .help("Choose what FreeTalker may read when dictation stops. Context is never sent to cloud providers.")
                SettingsHelpButton(
                    title: "Text context",
                    message: "Choose what FreeTalker may read when dictation stops. Context is never sent to cloud providers."
                )
            }
            Text(settings.localContextScope.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.localContextScope == .windowOCR, screenRecordingAuthorization != .granted {
                Label("Screen Recording permission is required; processing will fall back to app identity only.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if settings.localContextScope != .off, !accessibilityTrusted {
                Label("Accessibility permission is required; processing will fall back to app identity only.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Context is captured once when dictation stops, kept in memory, and used only with Apple's on-device processing. It is never sent to cloud providers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .help("Control what nearby text FreeTalker may read when dictation stops. Context stays on this Mac and is used only with Apple's on-device processing.")
    }

    @ViewBuilder
    private var automaticTemplateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Automatically choose template", isOn: $settings.automaticStyleEnabled)
                    .help(SettingsView.automaticTemplateHelp)
                SettingsHelpButton(
                    title: "Automatically choose template",
                    message: SettingsView.automaticTemplateHelp
                )
            }
            Text("Selects a built-in template based on the destination app and available context. App Rules take priority.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .help("Let FreeTalker choose a built-in template from the destination app and available on-device context. App Rules always take priority.")
    }

    @ViewBuilder
    private var appRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("App Rules")
                    .font(.headline)
                SettingsHelpButton(
                    title: "App Rule priority",
                    message: "App Rules take priority over automatic template selection and the Language Pin for the selected app."
                )
            }
            Text("Automatically use a specific Template and/or force a Transcript language when dictating into a chosen app, instead of the Active Template / Language Pin.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(AppSettings.unifiedAppRuleRows(appRules: settings.appRules, appLanguageRules: settings.appLanguageRules)) { row in
                HStack {
                    Text(displayName(forBundleID: row.bundleID))
                    Spacer()
                    if let templateID = row.templateID {
                        Text(templateStore.template(id: templateID)?.name ?? "(deleted template)")
                            .foregroundStyle(.secondary)
                    }
                    if let language = row.language {
                        Text(language == "en" ? "EN" : "PT")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Button {
                        let updated = AppSettings.removingAppRule(bundleID: row.bundleID, appRules: settings.appRules, appLanguageRules: settings.appLanguageRules)
                        settings.appRules = updated.appRules
                        settings.appLanguageRules = updated.appLanguageRules
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
                    Text("No template").tag(nil as String?)
                    ForEach(templateStore.templates) { template in
                        Text(template.name).tag(template.id as String?)
                    }
                }
                Picker("Language", selection: $newRuleLanguage) {
                    Text("No language").tag(nil as String?)
                    Text("English").tag("en" as String?)
                    Text("Portuguese").tag("pt" as String?)
                }
                Button("Add") {
                    guard let newRuleBundleID, newRuleTemplateID != nil || newRuleLanguage != nil else { return }
                    let updated = AppSettings.applyingAppRule(bundleID: newRuleBundleID, templateID: newRuleTemplateID, language: newRuleLanguage, appRules: settings.appRules, appLanguageRules: settings.appLanguageRules)
                    settings.appRules = updated.appRules
                    settings.appLanguageRules = updated.appLanguageRules
                    self.newRuleBundleID = nil
                    self.newRuleTemplateID = nil
                    self.newRuleLanguage = nil
                }
                .disabled(newRuleBundleID == nil || (newRuleTemplateID == nil && newRuleLanguage == nil))
            }
            Button("Refresh app list") { runningApps = Self.enumerateRunningApps() }
                .font(.caption)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var recordingCard: some View {
        SettingsCard(title: "Recording", subtitle: "Configure dictation shortcuts and hands-free recording") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Push-to-talk key")
                    .font(.headline)
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
                    Text("Insert Last Dictation key: \(settings.insertLastDictationHotKeySpec?.displayLabel ?? "Unbound")")
                    SettingsHelpButton(
                        title: "Insert Last Dictation key",
                        message: "Inserts your latest processed dictation from the Library at the cursor, using a brief clipboard swap (your clipboard is restored). Bind a different key from push-to-talk."
                    )
                    Spacer()
                    Button("Clear") {
                        // AppCoordinator re-plumbs the tap itself on any
                        // hotKeySpec/insertLastDictationHotKeySpec change (see its Combine
                        // subscriptions) — no manual call needed here.
                        settings.insertLastDictationHotKeySpec = nil
                        insertLastDictationRecorderMessage = nil
                    }
                    .disabled(settings.insertLastDictationHotKeySpec == nil)
                    Button(capturingInsertLastDictationHotKey ? "Press a key or combination… (⎋ cancels)" : "Change…") {
                        beginInsertLastDictationCapture()
                    }
                    .disabled(capturingInsertLastDictationHotKey)
                }
                Text("Re-inserts your most recent processed dictation at the cursor — nothing is re-recorded or re-processed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let insertLastDictationRecorderMessage {
                    Text(insertLastDictationRecorderMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                let voiceEditPresentation = VoiceEditHotKeyPresentation.make(
                    spec: settings.voiceEditHotKeySpec,
                    capturing: capturingVoiceEditHotKey
                )
                HStack {
                    Text(voiceEditPresentation.label)
                    SettingsHelpButton(
                        title: "Voice Edit key",
                        message: "Voice Edit records an instruction for selected text, then always shows a local preview before replacement."
                    )
                    Spacer()
                    Button("Clear") {
                        settings.voiceEditHotKeySpec = nil
                        voiceEditRecorderMessage = nil
                    }
                    .disabled(settings.voiceEditHotKeySpec == nil)
                    Button(voiceEditPresentation.actionLabel) { beginVoiceEditCapture() }
                        .disabled(capturingVoiceEditHotKey)
                }
                Text("Records an instruction for the selected text, then always shows a local preview before replacement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let voiceEditRecorderMessage {
                    Text(voiceEditRecorderMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 12)
            Divider()
            HStack {
                Stepper(value: $settings.handsFreeMaxMinutes, in: 1...60) {
                    Text("Auto-stop after \(settings.handsFreeMaxMinutes) minute\(settings.handsFreeMaxMinutes == 1 ? "" : "s")")
                }
                SettingsHelpButton(
                    title: "Hands-free recording",
                    message: "Tap the push-to-talk key to start a hands-free recording. Tap it again, click the HUD pill, or press Esc to stop or cancel."
                )
            }
            .padding(.top, 12)
            Text("Tap the push-to-talk key to start a hands-free recording that keeps going until you tap it again, click the HUD pill, or press Esc to cancel. Holding the key down instead is classic push-to-talk (unbounded, released to stop).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var floatingControlsCard: some View {
        SettingsCard(title: "Floating controls", subtitle: "Show a compact launcher at the edge of the screen") {
            Toggle("Show edge launcher", isOn: $settings.edgeLauncherEnabled)
                .padding(.vertical, 8)
            Divider()
            Picker("Screen edge", selection: $settings.edgeLauncherEdge) {
                ForEach(LauncherEdge.allCases, id: \.rawValue) { edge in
                    Text(edge.displayName)
                        .help(edge.explanation)
                        .tag(edge)
                }
            }
            .padding(.vertical, 8)
            .disabled(!settings.edgeLauncherEnabled)
            Text(settings.edgeLauncherEdge.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            Slider(value: $settings.edgeLauncherPosition, in: 0...1) {
                Text("Position along edge")
            }
            .padding(.vertical, 8)
            .disabled(!settings.edgeLauncherEnabled)
            Picker("Dictation language", selection: $settings.languagePin) {
                Text("Auto").tag("auto")
                Text("English").tag("en")
                Text("Portuguese").tag("pt")
            }
            .padding(.vertical, 8)
            .disabled(!settings.edgeLauncherEnabled)
        }
    }

    @ViewBuilder
    private var storageCard: some View {
        SettingsCard(title: "Storage", subtitle: "Choose how long local recordings and imports are retained") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Keep failed dictation audio", selection: $settings.recoveryRetention) {
                        ForEach(RecoveryRetention.allCases, id: \.rawValue) { value in
                            Text(RecoveryPresentation.retentionLabel(value)).tag(value)
                        }
                    }
                    SettingsHelpButton(
                        title: "Recovery retention",
                        message: "Recovery audio stays on this Mac and is removed automatically after the selected period."
                    )
                }
                Text("Recovery audio stays on this Mac and is removed automatically after the selected period. Choose Never to delete it yourself from Library → Recoveries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Keep imported transcripts", selection: $settings.mediaImportRetention) {
                        ForEach(MediaImportRetention.allCases, id: \.rawValue) { value in
                            Text(value.days.map { "\($0) day\($0 == 1 ? "" : "s")" } ?? "Until I delete them").tag(value)
                        }
                    }
                    SettingsHelpButton(
                        title: "Media import retention",
                        message: "Imported media, derived audio, transcripts, and speaker data stay on this Mac. The original source is never changed or deleted."
                    )
                }
                Text("Defaults to 7 days. Imported media, derived audio, transcripts, and speaker data stay on this Mac; the original source is never changed or deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button("Export Settings…") { exportSettings() }
                Text("Saves your preferences to a JSON file. Your API key is never included — it stays in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FreeTalker Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try settings.exportSettingsJSON()
            try data.write(to: url, options: .atomic)
        } catch {
            exportSettingsError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var audioAndTranscriptionCard: some View {
        SettingsCard(title: "Audio and transcription", subtitle: "Select input, speech recognition, and vocabulary preferences") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Microphone")
                    .font(.headline)
                Toggle("Reduce background noise", isOn: $settings.noiseSuppressionEnabled)
                Picker("Input device", selection: $settings.microphoneDeviceUID) {
                    Text("System default").tag(nil as String?)
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
                Button("Refresh device list") { inputDevices = AudioInputDevices.enumerate() }
                    .font(.caption)
            }
            .padding(.vertical, 12)
            Divider()
            transcriptionEngineSection
            Divider()
            vocabularySection
        }
    }

    @ViewBuilder
    private var transcriptionEngineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcription engine")
                .font(.headline)
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
            if settings.sttEngine == .whisperKit {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speech model")
                        .font(.headline)
                    ForEach(SpeechModelCatalog.entries, id: \.id) { entry in
                        speechModelRow(entry)
                    }
                }
                .padding(.top, 4)
                .onAppear {
                    Task { await speechModelStore.refresh() }
                    speechModelStore.refreshRemoteSupportOnce()
                }
            }
            HStack {
                Toggle("Live preview while recording", isOn: $settings.livePreviewEnabled)
                if settings.sttEngine == .cloud && !coordinator.whisperEngine.isLoaded {
                    SettingsHelpButton(
                        title: "Live preview while recording",
                        message: "Cloud STT is active and the on-device model isn't loaded, so preview is disabled to avoid per-chunk cloud uploads."
                    )
                }
            }
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
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vocabulary")
                .font(.headline)
            Text("One term per line — proper nouns, names, or jargon that should be recognized and spelled correctly. Used to bias transcription and post-processing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VocabularyEditorField(text: $settings.vocabularyText)
            if let truncation = settings.vocabularyTruncation {
                Text("Using first \(truncation.kept) of \(truncation.total) terms (limit: \(AppSettings.maxVocabularyTerms) terms / \(AppSettings.maxVocabularyCharacterBudget) characters).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var cloudProcessingCard: some View {
        SettingsCard(title: "Cloud processing", subtitle: "Configure optional post-processing with your own provider") {
            Picker("Provider", selection: $settings.llmProvider) {
                Text("Anthropic").tag(LLMProviderKind.anthropic)
                Text("Ollama").tag(LLMProviderKind.ollama)
                Text("OpenAI-compatible").tag(LLMProviderKind.openAICompatible)
            }
            .padding(.vertical, 8)
            .onChange(of: settings.llmProvider) { _, newProvider in
                cloudLLMKey = Keychain.get(account: Keychain.Account.cloudLLMKey(for: newProvider)) ?? ""
                cloudLLMKeyError = false
            }
            TextField("Base URL", text: $settings.cloudLLMBaseURL, prompt: providerDefaultBaseURL.map(Text.init))
                .padding(.vertical, 4)
            TextField("Model", text: $settings.cloudLLMModel, prompt: providerDefaultModel.map(Text.init))
                .padding(.vertical, 4)
            SecureField("API key", text: $cloudLLMKey)
                .padding(.vertical, 4)
                .onChange(of: cloudLLMKey) { _, newValue in
                    cloudLLMKeyError = !CloudLLMCredentialWriter.update(
                        newValue,
                        account: Keychain.Account.cloudLLMKey(for: settings.llmProvider)
                    )
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
            .padding(.vertical, 8)
            Text("Used for all templates whenever provider, model, and required API key are configured. OpenAI-compatible loopback HTTP endpoints can be used without a key.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(CloudPrivacyDisclosure.settings)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var outputLanguagePicker: some View {
        let presentation = OutputLanguageSettingsPresentation.make(snapshot: settings.cloudLLMSnapshot)
        let content = VStack(alignment: .leading) {
            Picker("Default output language", selection: $settings.defaultOutputLanguage) {
                ForEach(OutputLanguage.allCases, id: \.rawValue) { language in
                    Text(language.displayName)
                        .tag(language)
                        .disabled(!presentation.isEnabled(language))
                }
            }
            Text("Translation requires Cloud post-processing; Same as spoken does not.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(presentation.privacyDisclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let help = presentation.tooltip {
            content
                .help(help)
                .accessibilityHint(Text(presentation.accessibilityHelp ?? help))
        } else {
            content
        }
    }

    private var screenRecordingPermissionLabel: String {
        screenRecordingPresentation.label
    }

    private var screenRecordingPresentation: ScreenRecordingPermissionPresentation {
        .make(status: screenRecordingAuthorization, requestAttempted: screenRecordingRequestAttempted)
    }

    private var inputMonitoringPresentation: InputMonitoringPermissionPresentation {
        .make(rawAuthorized: inputMonitoringAuthorized, hotKeyOperational: coordinator.isHotKeyListening)
    }

    @ViewBuilder
    private func speechModelRow(_ entry: SpeechModelCatalogEntry) -> some View {
        let state = speechModelStore.states[entry.id] ?? .init()
        let selected = settings.whisperModel == entry.id
        let presentation = SpeechModelRowPresentation.make(
            state: state,
            selected: selected,
            activeDownloadVariant: speechModelStore.activeDownloadVariant
        )
        HStack(alignment: .center, spacing: 10) {
            Button {
                Task { await coordinator.selectSpeechModelFromUser(entry.id) }
            } label: {
                Image(systemName: state.active ? "largecircle.fill.circle" : (selected ? "circle.inset.filled" : "circle"))
                    .accessibilityLabel(SpeechModelRowPresentation.radioAccessibilityLabel(
                        displayName: entry.displayName,
                        active: state.active,
                        selected: selected
                    ))
                    .accessibilityValue(SpeechModelRowPresentation.radioAccessibilityLabel(
                        displayName: entry.displayName,
                        active: state.active,
                        selected: selected
                    ))
            }
            .buttonStyle(.plain)
            .disabled(!presentation.canSelect)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                Text("\(entry.approximateSize) · \(entry.compactTradeoff)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(presentation.status)
                    .font(.caption)
                    .foregroundStyle(state.supported || state.active ? .secondary : .tertiary)
                if let caption = presentation.actionCaption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch presentation.action {
            case .download:
                Button("Download") { Task { await speechModelStore.download(entry.id) } }
                    .disabled(!presentation.actionEnabled)
            case .delete:
                Button("Delete") { modelPendingDeletion = entry }
            case .none:
                if case .downloading(let progress) = state.phase {
                    ProgressView(value: progress).frame(width: 72)
                }
            }
        }
        .help(entry.quickTip)
        .accessibilityHint(entry.quickTip)
    }

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
            if let insertLastDictation = settings.insertLastDictationHotKeySpec {
                if HotKeySpec.collides(spec, insertLastDictation) {
                    hotKeyRecorderMessage = "Same as the Insert Last Dictation key — pick a different chord."
                    return
                }
                if HotKeySpec.insertLastDictationShadowsHeldPTT(pttSpec: spec, insertLastDictationSpec: insertLastDictation) {
                    hotKeyRecorderMessage = "Would trigger before the Insert Last Dictation key — pick a different chord."
                    return
                }
            }
            hotKeyRecorderMessage = nil
            // AppCoordinator re-plumbs the tap itself on any
            // hotKeySpec/insertLastDictationHotKeySpec change (see its Combine subscriptions) —
            // no manual call needed here.
            settings.hotKeySpec = spec
        }
    }

    private func beginInsertLastDictationCapture() {
        capturingInsertLastDictationHotKey = true
        NSApp.activate()
        NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
        let session = HotKeyCapture.Session()
        insertLastDictationCaptureSession = session
        session.start { spec in
            defer {
                capturingInsertLastDictationHotKey = false
                insertLastDictationCaptureSession = nil
            }
            guard let spec else { return } // Escape cancelled the capture.
            guard HotKeySpec.isValidInsertLastDictationSpec(spec) else {
                insertLastDictationRecorderMessage = "Insert Last Dictation needs a key, not just modifiers."
                return
            }
            guard !HotKeySpec.collides(spec, settings.hotKeySpec) else {
                insertLastDictationRecorderMessage = "Same as the push-to-talk key — pick a different chord."
                return
            }
            guard !HotKeySpec.insertLastDictationShadowsHeldPTT(pttSpec: settings.hotKeySpec, insertLastDictationSpec: spec) else {
                insertLastDictationRecorderMessage = "Would trigger push-to-talk before this key — pick a different chord."
                return
            }
            insertLastDictationRecorderMessage = nil
            // AppCoordinator re-plumbs the tap itself on any
            // hotKeySpec/insertLastDictationHotKeySpec change (see its Combine subscriptions) —
            // no manual call needed here.
            settings.insertLastDictationHotKeySpec = spec
        }
    }

    private func beginVoiceEditCapture() {
        capturingVoiceEditHotKey = true
        NSApp.activate()
        NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
        let session = HotKeyCapture.Session()
        voiceEditCaptureSession = session
        session.start { spec in
            defer {
                capturingVoiceEditHotKey = false
                voiceEditCaptureSession = nil
            }
            guard let spec else { return }
            guard HotKeySpec.isValidInsertLastDictationSpec(spec) else {
                voiceEditRecorderMessage = "Voice Edit needs a key, not just modifiers."
                return
            }
            guard HotKeySpec.validActionSpec(
                spec,
                pttSpec: settings.hotKeySpec,
                otherActionSpec: settings.insertLastDictationHotKeySpec
            ) != nil else {
                voiceEditRecorderMessage = "This conflicts with another hotkey — pick a different chord."
                return
            }
            voiceEditRecorderMessage = nil
            settings.voiceEditHotKeySpec = spec
        }
    }

    /// "Test connection" for the Cloud STT (BYOK) section. Snapshots the base URL/key into
    /// locals before the `await` so a mid-flight edit to the fields can't retroactively change
    /// the connection target. `ConnectionTestOutcome.message` is the only thing ever assigned to
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
    /// three can never disagree about the connection target. See CloudLLMSettingsSnapshot's doc
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
    @State private var importingFile = false
    @State private var importError: String?

    var body: some View {
        SettingsEditorPage(title: "Templates", subtitle: "Create and refine reusable dictation formats") {
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
                            try? store.upsert(new)
                            selectedID = new.id
                        } label: { Image(systemName: "plus") }
                        Button {
                            if let selectedID { store.delete(id: selectedID); self.selectedID = nil }
                        } label: { Image(systemName: "minus") }
                        .disabled(selectedID == nil)
                        Button {
                            importingFile = true
                        } label: { Image(systemName: "square.and.arrow.down") }
                        .help("Import Templates")
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
        .fileImporter(
            isPresented: $importingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importTemplates(from: url) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(
            "Import failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "The templates couldn't be imported.")
        }
    }

    private func importTemplates(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let existingIDs = Set(store.templates.map(\.id))
            let count = try store.importTemplates(from: data)
            if count > 0, let imported = store.templates.first(where: { !existingIDs.contains($0.id) }) {
                selectedID = imported.id
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct TemplateEditor: View {
    @State var template: Template
    @ObservedObject private var store = TemplateStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var nameError: String?

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
                .onChange(of: template.name) { _, _ in persist() }
            if let nameError {
                Text(nameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
                .onChange(of: template.prompt) { _, _ in persist() }
        }
        .padding()
    }

    private func persist() {
        do {
            try store.upsert(template)
            nameError = nil
        } catch {
            nameError = error.localizedDescription
        }
    }
}
