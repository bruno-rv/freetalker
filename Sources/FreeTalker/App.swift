import AppKit
import Combine
import SwiftUI

@main
struct FreeTalkerApp: App {
    private static var instanceLease: AppInstanceLease?
    private static var floatingControlsController: FloatingControlsController?

    init() {
        let currentApplication = NSRunningApplication.current
        let claim = AppLifecycleWindowPolicy.claimInstance(
            path: AppLifecycleWindowPolicy.instanceLeasePath,
            maxAttempts: 10,
            activateExistingOwner: { ownerPID in
                if let existingApplication = AppLifecycleWindowPolicy.existingOwner(
                    processIdentifier: ownerPID,
                    for: currentApplication
                ) {
                    existingApplication.activate(options: [.activateAllWindows])
                    return true
                }
                return false
            },
            wait: {
                Thread.sleep(forTimeInterval: 0.05)
            }
        )
        guard let lease = claim.lease else {
            NSApplication.shared.terminate(nil)
            return
        }
        Self.instanceLease = lease

        // One-time migration of the legacy shared BYOK LLM Keychain item into the active
        // provider's scoped account. Deliberately placed here rather than in `AppSettings.init`
        // so it runs once during app startup against the real Keychain.
        CloudLLMKeyMigration.migrateIfNeeded(provider: AppSettings.shared.llmProvider, store: KeychainSecretStore())
        // Triggers the system Accessibility prompt on first launch if not already granted
        // (a no-op, no dialog, if already trusted or already declined once).
        Permissions.requestAccessibility()
        // Same idea for Microphone: primes the TCC prompt at launch so a first-time user isn't
        // met with a silent capture from `.notDetermined` status the first time they hold PTT.
        // No-op if already determined (granted or denied). See live-mic silence root cause H1.
        AppCoordinator.shared.primeMicrophonePermission()
        AppCoordinator.shared.speechModelStore.refreshRemoteSupportOnce()
        Task { await AppCoordinator.shared.speechModelStore.refresh() }
        Task { await AppCoordinator.shared.launchRecoveryWorkflows() }
        Task { await AppCoordinator.shared.launchMediaImportWorkflows() }
        if AppSettings.shared.sttEngine == .whisperKit {
            Task { await AppCoordinator.shared.whisperEngine.preload() }
        }
        // One unified entry point: creates the tap, or (on failure) starts the 2s retry poll
        // and status text — the same path also used by app activation and hotkey reassignment.
        AppCoordinator.shared.ensureHotKeyListening()
        _ = ScratchpadWindowController.shared

        let floatingControlsController = FloatingControlsController(
            outputSelection: { AppCoordinator.shared.recordingOutputSelection },
            outputUpdates: AppCoordinator.shared.objectWillChange
                .map { _ in () }
                .eraseToAnyPublisher(),
            isRecording: { AppCoordinator.shared.isRecording },
            callbacks: .init(
            onDictation: {
                AppCoordinator.shared.startHandsFreeRecording(destination: .external)
            },
            onScratchpad: {
                ScratchpadWindowController.shared.open()
            },
            onOpenSettings: {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.windows
                    .first { $0.title == "Settings" }?
                    .makeKeyAndOrderFront(nil)
            },
            onLanguage: { AppSettings.shared.languagePin = $0 },
            onOutput: { AppCoordinator.shared.selectRecordingOutput($0) }
        ))
        Self.floatingControlsController = floatingControlsController
        floatingControlsController.start()
    }

    var body: some Scene {
        MenuBarExtra("FreeTalker", systemImage: "waveform") {
            MenuBarContentView()
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .background(SettingsWindowConfigurator())
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuBarContentView: View {
    @ObservedObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var templateStore = TemplateStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted()

    var body: some View {
        Group {
            ForEach(templateStore.templates) { template in
                Button {
                    settings.activeTemplateID = template.id
                } label: {
                    if template.id == settings.activeTemplateID {
                        Label(template.name, systemImage: "checkmark")
                    } else {
                        Text(template.name)
                    }
                }
            }

            Divider()

            // Persistent Auto/English/Portuguese toggle forcing Transcript language, absent a
            // more specific override (an app rule, or the panel's one-shot choice).
            ForEach(Self.languagePinOptions, id: \.code) { option in
                Button {
                    settings.languagePin = option.code
                } label: {
                    if settings.languagePin == option.code {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }

            Divider()

            Text(coordinator.engineStatusText)

            if let hotKeyStatusText = coordinator.hotKeyStatusText {
                Text("⚠️ \(hotKeyStatusText)")
            }

            if !accessibilityTrusted {
                Button("⚠️ Accessibility permission required…") {
                    Permissions.openAccessibilitySettings()
                }
            }

            Divider()

            Button("Library…") {
                SettingsNavigator.shared.pendingDestination = .library
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            Button("Scratchpad…") { ScratchpadWindowController.shared.open() }
            Button("Settings…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            Button("Check for Updates…") {
                Task {
                    let report = await SelfUpdater.check()
                    presentSelfUpdateResult(report)
                }
            }

            Divider()

            Button("Quit FreeTalker") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear { accessibilityTrusted = Permissions.isAccessibilityTrusted() }
    }

    private static let languagePinOptions: [(code: String, label: String)] = [
        ("auto", "Auto"),
        ("en", "English"),
        ("pt", "Portuguese")
    ]
}

/// Activates FreeTalker before presenting — mirrors the "Settings…" button above. Without
/// this an `LSUIElement` app's alert can appear behind the frontmost app with no focus.
@MainActor
private func presentSelfUpdateResult(_ report: SelfUpdater.CheckReport) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    switch report.availability {
    case .upToDate:
        alert.messageText = "You're up to date"
        if let hash = report.currentShortHash {
            alert.informativeText = "Running \(hash)."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .unavailable(let reason):
        alert.messageText = "Updates unavailable"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .blockedByLocalChanges:
        alert.messageText = "Update skipped"
        alert.informativeText = "The repo has local changes, update skipped."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .available(let behindCount):
        alert.messageText = "Update available"
        let commitWord = behindCount == 1 ? "commit" : "commits"
        if let hash = report.currentShortHash {
            alert.informativeText = "You're on \(hash), \(behindCount) \(commitWord) behind."
        } else {
            alert.informativeText = "\(behindCount) \(commitWord) behind origin/main."
        }
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let repoPath = report.repoPath {
            SelfUpdater.performUpdate(repoPath: repoPath)
        }
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowObserverView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppLifecycleWindowPolicy.configureFocusableUtilityWindow(window)
        window.makeKeyAndOrderFront(nil)
    }
}
