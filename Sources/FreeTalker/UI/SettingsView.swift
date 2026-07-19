import AppKit
import SwiftUI

enum NotchpadSettingsCopy {
    static let toggleTitle = "Show FreeTalker in the notch"
    static let caption = "All HUD presentations — recording panel, status flashes, and translation recovery — move to the notch on the built-in display; falls back to the floating panel in clamshell or external-only setups."
}

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

                UsageStatisticsView(isActive: selection == .stats)
                    .opacity(selection == .stats ? 1 : 0)
                    .allowsHitTesting(selection == .stats)
                    .disabled(selection != .stats)
                    .accessibilityHidden(selection != .stats)
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
        case .templates, .snippets, .library, .stats:
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
    @State private var capturingHistoryPanelHotKey = false
    @State private var historyPanelCaptureSession: HotKeyCapture.Session?
    @State private var historyPanelRecorderMessage: String?
    @State private var inputDevices: [AudioInputDevices.Device] = []
    @State private var runningApps: [NSRunningApplication] = []
    @State private var newRuleBundleID: String?
    @State private var newRuleTemplateID: String?
    @State private var newRuleLanguage: String?

    @State private var cloudSTTKey = Keychain.get(account: Keychain.Account.cloudSTTKey(for: AppSettings.shared.cloudSTTProvider)) ?? ""
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
    @State private var backupError: String?
    @State private var backupRestoreSummary: String?
    @State private var restoringBackup = false

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            settingsPage(
                .privacy,
                title: "Privacy",
                subtitle: "Permissions and on-device context"
            ) {
                permissionsCard
                permissionDiagnosisCard
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
                subtitle: "Edge launcher and Notchpad placement"
            ) {
                floatingControlsCard
                notchpadCard
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
        .fileImporter(
            isPresented: $restoringBackup,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { restoreBackup(from: url) }
            case .failure(let error):
                backupError = error.localizedDescription
            }
        }
        .alert(
            "Backup failed",
            isPresented: Binding(
                get: { backupError != nil },
                set: { if !$0 { backupError = nil } }
            )
        ) {
            Button("OK") { backupError = nil }
        } message: {
            Text(backupError ?? "The backup couldn't be completed.")
        }
        .alert(
            "Restore complete",
            isPresented: Binding(
                get: { backupRestoreSummary != nil },
                set: { if !$0 { backupRestoreSummary = nil } }
            )
        ) {
            Button("OK") { backupRestoreSummary = nil }
        } message: {
            Text(backupRestoreSummary ?? "")
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

    /// Permission Diagnosis (PLAN.md F2.2, CONTEXT.md): on-demand check of real capability
    /// (tap-operational status) rather than the raw TCC claims `permissionsCard` above shows.
    @ViewBuilder
    private var permissionDiagnosisCard: some View {
        SettingsCard(
            title: "Permission Diagnosis",
            subtitle: "Check whether granted-looking permissions actually work"
        ) {
            Button("Run Diagnosis") { coordinator.refreshPermissionDiagnosis() }
                .padding(.bottom, 8)
            let items = coordinator.permissionDiagnosis.items
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                permissionDiagnosisRow(item)
                if index < items.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func permissionDiagnosisRow(_ item: PermissionDiagnosisItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(Self.diagnosisColor(for: item.state))
                    .frame(width: 8, height: 8)
                Text(item.title)
                Spacer()
                if item.showsRelaunch {
                    Button("Relaunch FreeTalker") { AppRelaunch.relaunch() }
                }
                if item.showsOpenSystemSettings {
                    Button("Open System Settings") { Self.openSystemSettings(for: item.kind) }
                }
            }
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private static func diagnosisColor(for state: PermissionState) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .staleGranted: return .orange
        case .notDetermined, .unknown: return .gray
        }
    }

    private static func openSystemSettings(for kind: PermissionKind) {
        switch kind {
        case .accessibility: Permissions.openAccessibilitySettings()
        case .microphone: Permissions.openMicrophoneSettings()
        case .inputMonitoring: Permissions.openInputMonitoringSettings()
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
                        Text(language.uppercased())
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
                    ForEach(DictationLanguagePresentation.options(for: settings.dictationLanguages), id: \.code) { option in
                        Text(option.label).tag(option.code as String?)
                    }
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
                HStack {
                    Text("Dictation History key: \(settings.historyPanelHotKeySpec?.displayLabel ?? "Unbound")")
                    SettingsHelpButton(
                        title: "Dictation History key",
                        message: "Opens a search panel over your Dictation History for one-click insertion. The \"Dictation History…\" menu item is always available."
                    )
                    Spacer()
                    Button("Clear") {
                        settings.historyPanelHotKeySpec = nil
                        historyPanelRecorderMessage = nil
                    }
                    .disabled(settings.historyPanelHotKeySpec == nil)
                    Button(capturingHistoryPanelHotKey ? "Press a key or combination… (⎋ cancels)" : "Change…") {
                        beginHistoryPanelCapture()
                    }
                    .disabled(capturingHistoryPanelHotKey)
                }
                Text("Opens a search panel over your Dictation History — click a result to insert it, or press Esc to close.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let historyPanelRecorderMessage {
                    Text(historyPanelRecorderMessage)
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
                ForEach(DictationLanguagePresentation.options(for: settings.dictationLanguages), id: \.code) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .padding(.vertical, 8)
            .disabled(!settings.edgeLauncherEnabled)
        }
    }

    @ViewBuilder
    private var notchpadCard: some View {
        SettingsCard(title: "Notchpad", subtitle: "Show FreeTalker in the MacBook notch when available") {
            Toggle(NotchpadSettingsCopy.toggleTitle, isOn: $settings.notchpadEnabled)
                .padding(.vertical, 8)
            Text(NotchpadSettingsCopy.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
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
                HStack(spacing: 12) {
                    Button("Back Up…") { backUp() }
                    Button("Restore…") { restoringBackup = true }
                }
                Text("Back Up saves your settings, templates, and snippets to a JSON file. Your API key is never included — it stays in the macOS Keychain. Restore overwrites your current settings and merges in templates/snippets; existing templates and snippets are never changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        }
    }

    private func backUp() {
        guard let snippetStore = coordinator.snippetStore else {
            backupError = coordinator.snippetStoreInitializationError ?? "Snippet storage isn't available."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = BackupBundle.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await BackupBundle.export(settings: settings, templateStore: templateStore, snippetStore: snippetStore)
                try data.write(to: url, options: .atomic)
            } catch {
                backupError = "Could not save backup: \(error.localizedDescription)"
            }
        }
    }

    private func restoreBackup(from url: URL) {
        guard let snippetStore = coordinator.snippetStore else {
            backupError = coordinator.snippetStoreInitializationError ?? "Snippet storage isn't available."
            return
        }
        Task {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let result = try await BackupBundle.restore(data: data, settings: settings, templateStore: templateStore, snippetStore: snippetStore)
                backupRestoreSummary = Self.summary(for: result)
            } catch {
                backupError = error.localizedDescription
            }
        }
    }

    private static func summary(for result: BackupBundleImportResult) -> String {
        "Templates: \(result.templatesImported) imported, \(result.templatesSkipped) skipped.\n"
            + "Snippets: \(result.snippetsImported) imported, \(result.snippetsSkipped) skipped.\n"
            + "Settings: \(result.settingsApplied ? "restored" : "not restored")."
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
                if newValue == .cloud {
                    cloudSTTKey = Keychain.get(account: Keychain.Account.cloudSTTKey(for: settings.cloudSTTProvider)) ?? ""
                    cloudSTTKeyError = false
                    cloudSTTTestResult = nil
                } else if newValue == .whisperKit {
                    Task { await coordinator.whisperEngine.preload() }
                }
            }
            Text(coordinator.engineStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            dictationLanguagesSection
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
                Picker("Provider", selection: $settings.cloudSTTProvider) {
                    ForEach(CloudSTTProviderKind.allCases, id: \.self) { provider in
                        Text(provider.settingsName).tag(provider)
                    }
                }
                .onChange(of: settings.cloudSTTProvider) { _, newProvider in
                    cloudSTTKey = Keychain.get(account: Keychain.Account.cloudSTTKey(for: newProvider)) ?? ""
                    cloudSTTKeyError = false
                    cloudSTTTestResult = nil
                }
                TextField("Model", text: $settings.cloudSTTModel)
                TextField("Base URL", text: $settings.cloudSTTBaseURL)
                    .disabled(settings.cloudSTTProvider == .openAI)
                    .help(settings.cloudSTTProvider == .openAI
                        ? "OpenAI uses https://api.openai.com/v1."
                        : "Custom OpenAI-compatible endpoint serving /audio/transcriptions.")
                if CloudSTTProviderKind.isKnownNonTranscriptionSTTBaseURL(settings.cloudSTTBaseURL) {
                    Label("Ollama does not provide speech-to-text. This endpoint has no /audio/transcriptions — recordings will fail. Use WhisperKit for transcription and Ollama for Cloud processing only.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                SecureField("API key", text: $cloudSTTKey)
                    .onChange(of: cloudSTTKey) { _, newValue in
                        cloudSTTKeyError = !CloudSTTCredentialWriter.update(
                            newValue,
                            account: Keychain.Account.cloudSTTKey(for: settings.cloudSTTProvider)
                        )
                    }
                if cloudSTTKeyError {
                    Text("Failed to save key to Keychain")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Test connection") { testCloudSTTConnection() }
                        .disabled(cloudSTTTesting || !AppCoordinator.isCloudSTTConfigured(
                            provider: settings.cloudSTTProvider,
                            model: settings.cloudSTTModel,
                            baseURL: settings.cloudSTTBaseURL,
                            key: cloudSTTKey
                        ))
                    if cloudSTTTesting {
                        ProgressView().controlSize(.small)
                    } else if let cloudSTTTestResult {
                        Text(cloudSTTTestResult)
                            .font(.caption)
                            .foregroundStyle(cloudSTTTestResult.hasSuffix("Connected ✓") ? .green : .red)
                    }
                }
                Text("Cloud STT sends audio to the selected provider's OpenAI-compatible /audio/transcriptions endpoint. Anthropic and Ollama are available for Cloud processing only; they do not provide this transcription endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var dictationLanguagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("Dictation languages")
                    .font(.headline)
                SettingsHelpButton(
                    title: "Dictation languages",
                    message: "Constrains on-device (WhisperKit) spoken-language auto-detection to this set. Cloud STT does not honor this set — it only accepts a single forced language, chosen elsewhere. Transcribability is also bounded by the selected Speech model."
                )
            }
            Text("Constrains on-device (WhisperKit) spoken-language auto-detection. Cloud STT does not honor this set.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(DictationLanguage.allCases, id: \.rawValue) { language in
                let isOn = settings.dictationLanguages.contains(language.rawValue)
                Toggle(language.displayName, isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        var codes = settings.dictationLanguages
                        if newValue {
                            if !codes.contains(language.rawValue) { codes.append(language.rawValue) }
                        } else {
                            codes.removeAll { $0 == language.rawValue }
                        }
                        settings.dictationLanguages = codes
                    }
                ))
                // Prevents unchecking the last remaining language from the UI — the normalizer
                // (min 1, falls back to the default pair) is the safety net, not the primary
                // guard, so this stays in sync with it rather than surprising the user by
                // silently re-adding English/Portuguese. See PLAN.md F5.1/F5.6.
                .disabled(isOn && settings.dictationLanguages.count == 1)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vocabulary")
                .font(.headline)
            Text("Shared across WhisperKit, Cloud STT, and post-processing. One term per line — proper nouns, names, or jargon that should be recognized and spelled correctly.")
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
            // Centralized four-way validation (PLAN.md F3.1): a new PTT candidate must not
            // collide with, or be shadow-engaged before, ANY currently-bound action spec — not
            // just Insert Last Dictation.
            let actions: [(label: String, spec: HotKeySpec?)] = [
                ("Insert Last Dictation", settings.insertLastDictationHotKeySpec),
                ("Voice Edit", settings.voiceEditHotKeySpec),
                ("Dictation History", settings.historyPanelHotKeySpec)
            ]
            for (label, action) in actions {
                guard let action else { continue }
                if HotKeySpec.collides(spec, action) {
                    hotKeyRecorderMessage = "Same as the \(label) key — pick a different chord."
                    return
                }
                if HotKeySpec.insertLastDictationShadowsHeldPTT(pttSpec: spec, insertLastDictationSpec: action) {
                    hotKeyRecorderMessage = "Would trigger before the \(label) key — pick a different chord."
                    return
                }
            }
            hotKeyRecorderMessage = nil
            // AppCoordinator re-plumbs the tap itself on any hotkey-spec change (see its Combine
            // subscriptions) — no manual call needed here.
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
            guard HotKeySpec.validActionSpec(
                spec,
                pttSpec: settings.hotKeySpec,
                otherActionSpecs: [settings.voiceEditHotKeySpec, settings.historyPanelHotKeySpec]
            ) != nil else {
                insertLastDictationRecorderMessage = "This conflicts with another hotkey — pick a different chord."
                return
            }
            insertLastDictationRecorderMessage = nil
            // AppCoordinator re-plumbs the tap itself on any hotkey-spec change (see its Combine
            // subscriptions) — no manual call needed here.
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
                otherActionSpecs: [settings.insertLastDictationHotKeySpec, settings.historyPanelHotKeySpec]
            ) != nil else {
                voiceEditRecorderMessage = "This conflicts with another hotkey — pick a different chord."
                return
            }
            voiceEditRecorderMessage = nil
            settings.voiceEditHotKeySpec = spec
        }
    }

    private func beginHistoryPanelCapture() {
        capturingHistoryPanelHotKey = true
        NSApp.activate()
        NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
        let session = HotKeyCapture.Session()
        historyPanelCaptureSession = session
        session.start { spec in
            defer {
                capturingHistoryPanelHotKey = false
                historyPanelCaptureSession = nil
            }
            guard let spec else { return }
            guard HotKeySpec.isValidInsertLastDictationSpec(spec) else {
                historyPanelRecorderMessage = "Dictation History needs a key, not just modifiers."
                return
            }
            guard HotKeySpec.validActionSpec(
                spec,
                pttSpec: settings.hotKeySpec,
                otherActionSpecs: [settings.insertLastDictationHotKeySpec, settings.voiceEditHotKeySpec]
            ) != nil else {
                historyPanelRecorderMessage = "This conflicts with another hotkey — pick a different chord."
                return
            }
            historyPanelRecorderMessage = nil
            settings.historyPanelHotKeySpec = spec
        }
    }

    /// "Test connection" for the Cloud STT (BYOK) section. Snapshots the provider, model, base
    /// URL, and key into
    /// locals before the `await` so a mid-flight edit to the fields can't retroactively change
    /// the connection target. `ConnectionTestOutcome.message` is the only thing ever assigned to
    /// `cloudSTTTestResult` — never the thrown error's description, which could carry a response
    /// body. See Task 3 security requirement.
    private func testCloudSTTConnection() {
        cloudSTTTesting = true
        cloudSTTTestResult = nil
        let provider = settings.cloudSTTProvider
        let model = settings.cloudSTTModel
        let baseURL = settings.cloudSTTBaseURL
        let key = cloudSTTKey
        Task {
            let outcome: ConnectionTestOutcome
            do {
                // The endpoint probe is provider/model agnostic, but capture these fields with
                // the request so the result cannot be associated with a later edit.
                _ = provider
                _ = model
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

/// Pure ordering guarantee for the voice-commands toggle (Codex round-5 finding 7): a keyword
/// edit still pending in the text field's local buffer must be committed BEFORE the toggle flips
/// off and the field is removed from the view hierarchy. Relying solely on SwiftUI's
/// focus-loss `.onChange` to fire first is not guaranteed to happen before the toggle's own
/// `.onChange` resets the buffer, so a fast toggle-off could discard an uncommitted edit.
/// Extracted as a free function (rather than inlined in the `Toggle` binding) so the ordering
/// itself is unit-testable without a SwiftUI rendering context — see
/// `VoiceCommandsSettingsTests`.
enum VoiceCommandsToggleCommit {
    static func apply(_ newValue: Bool, commitPendingKeywords: () -> Void, setEnabled: (Bool) -> Void) {
        if !newValue { commitPendingKeywords() }
        setEnabled(newValue)
    }
}

/// Codex round-6 finding 6: Backup Bundle restore can update `settings.commandKeywords` directly
/// while `TemplatesSettingsView` is mounted but not the visible tab — previously only a toggle
/// change resynchronized `keywordsText`, so a stale pre-restore buffer could survive the restore
/// and get committed right back over it on the next toggle-off. Extracted as a free function/enum
/// for the same testability reason as `VoiceCommandsToggleCommit` above — so the dirty-tracking
/// policy is unit-testable without a SwiftUI rendering context.
enum VoiceCommandsKeywordsBuffer {
    /// `settings.commandKeywords` changed (externally, e.g. a restore, or as an echo of this
    /// pane's own `commitKeywords()`). A dirty buffer holds an uncommitted user edit that must
    /// never be silently discarded by an external change; a clean buffer always tracks the live
    /// value.
    static func reconciled(isDirty: Bool, liveKeywords: [String], currentText: String) -> String {
        isDirty ? currentText : liveKeywords.joined(separator: ", ")
    }

    /// Whether `commitKeywords()` should write `keywordsText` into `settings.commandKeywords`. A
    /// clean buffer already tracks the live value, so committing it verbatim on toggle-off would
    /// clobber a restore that landed while this buffer sat untouched.
    static func shouldCommit(isDirty: Bool) -> Bool { isDirty }
}

private struct TemplatesSettingsView: View {
    @ObservedObject private var store = TemplateStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedID: String?
    @State private var importingFile = false
    @State private var importError: String?
    @State private var exportError: String?
    @State private var keywordsText = AppSettings.shared.commandKeywords.joined(separator: ", ")
    @State private var keywordsTextIsDirty = false
    @FocusState private var keywordsFieldFocused: Bool

    /// Only the TextField writes through this binding, so a user keystroke is the only thing that
    /// marks the buffer dirty — every programmatic resync below (`commitKeywords()`, the two
    /// `.onChange` handlers) assigns `keywordsText` directly and never touches this.
    private var keywordsTextBinding: Binding<String> {
        Binding(
            get: { keywordsText },
            set: { keywordsText = $0; keywordsTextIsDirty = true }
        )
    }

    var body: some View {
        SettingsEditorPage(title: "Templates", subtitle: "Create and refine reusable dictation formats") {
            VStack(alignment: .leading, spacing: 12) {
                voiceCommandsSection

                HStack(spacing: 12) {
                    Button("Import…", systemImage: "square.and.arrow.down") {
                        importingFile = true
                    }
                    Button("Export…", systemImage: "square.and.arrow.up") {
                        exportTemplates()
                    }
                    Button("New Template", systemImage: "plus") {
                        let new = Template(id: UUID().uuidString, name: "New Template", prompt: "")
                        try? store.upsert(new)
                        selectedID = new.id
                    }
                    Button("Delete Template", systemImage: "minus") {
                        if let selectedID { try? store.delete(id: selectedID); self.selectedID = nil }
                    }
                    .disabled(selectedID == nil)
                    Spacer()
                }

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
                    .frame(
                        minWidth: SplitViewMetrics.templatesMaster.minimum,
                        idealWidth: SplitViewMetrics.templatesMaster.ideal,
                        maxWidth: SplitViewMetrics.templatesMaster.maximum
                    )

                    if let selectedID, let template = store.template(id: selectedID) {
                        TemplateEditor(template: template)
                            .id(template.id)
                            .frame(minWidth: SplitViewMetrics.detailMinimum, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Select a template")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: SplitViewMetrics.detailMinimum, maxWidth: .infinity, maxHeight: .infinity)
                    }
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
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "The templates couldn't be exported.")
        }
    }

    @ViewBuilder
    private var voiceCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("Voice commands")
                    .font(.headline)
                SettingsHelpButton(
                    title: "Voice commands",
                    message: "When enabled, post-processing recognizes spoken commands (e.g. \"command new paragraph\") in your dictation and follows them, using the keywords below. Off by default. Disabled for translation and Scratchpad rewrite actions regardless of this setting."
                )
            }

            if !store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Label(
                        "A built-in template still has an edited copy of the old spoken-command rules text, which wasn't automatically removed. Voice commands may behave inconsistently for it until you edit or remove that text.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Spacer()
                    Button("Dismiss") { store.dismissLegacyCommandRuleWarning() }
                        .font(.caption)
                }
            }

            Toggle("Enable voice commands", isOn: Binding(
                get: { settings.voiceCommandsEnabled },
                set: { newValue in
                    VoiceCommandsToggleCommit.apply(
                        newValue,
                        commitPendingKeywords: commitKeywords,
                        setEnabled: { settings.voiceCommandsEnabled = $0 }
                    )
                }
            ))

            if settings.voiceCommandsEnabled {
                Text("Keywords (comma-separated, 1–5, letters only)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("command, comando", text: keywordsTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .focused($keywordsFieldFocused)
                    .onSubmit(commitKeywords)
            }
        }
        .padding(.bottom, 4)
        .onChange(of: keywordsFieldFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused { commitKeywords() }
        }
        .onChange(of: settings.voiceCommandsEnabled) { _, _ in
            // Codex round-7 minor finding 1: an in-app toggle-off already commits (and clears
            // dirty) via `VoiceCommandsToggleCommit.apply` before this fires, so this only ever
            // observes a genuinely dirty buffer here when the toggle changed for some OTHER
            // reason (e.g. a Backup Bundle restore landing while this pane is mounted but not
            // focused) — exactly the case the buffer's "dirty is never overwritten" policy
            // exists to protect. Route through the same reconciliation the sibling
            // `commandKeywords` handler below uses instead of unconditionally clobbering it.
            keywordsText = VoiceCommandsKeywordsBuffer.reconciled(
                isDirty: keywordsTextIsDirty, liveKeywords: settings.commandKeywords, currentText: keywordsText
            )
        }
        .onChange(of: settings.commandKeywords) { _, newValue in
            keywordsText = VoiceCommandsKeywordsBuffer.reconciled(
                isDirty: keywordsTextIsDirty, liveKeywords: newValue, currentText: keywordsText
            )
        }
    }

    private func commitKeywords() {
        guard VoiceCommandsKeywordsBuffer.shouldCommit(isDirty: keywordsTextIsDirty) else { return }
        settings.commandKeywords = keywordsText.split(separator: ",").map(String.init)
        keywordsText = settings.commandKeywords.joined(separator: ", ")
        keywordsTextIsDirty = false
    }

    private func importTemplates(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let incoming = try await Task.detached(priority: .userInitiated) {
                    try TemplateStore.loadTemplates(from: url)
                }.value
                let existingIDs = Set(store.templates.map(\.id))
                let result = try store.importTemplates(incoming)
                if result.importedCount > 0, let imported = store.templates.first(where: { !existingIDs.contains($0.id) }) {
                    selectedID = imported.id
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func exportTemplates() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "FreeTalker Templates.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let data = try store.exportTemplatesJSON()
            try data.write(to: destination, options: .atomic)
        } catch {
            exportError = "Could not save templates: \(error.localizedDescription)"
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
