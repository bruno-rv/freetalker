import AppKit
import SwiftUI

@main
struct FreeTalkerApp: App {
    @ObservedObject private var coordinator = AppCoordinator.shared

    init() {
        if CommandLine.arguments.contains("--self-check") {
            SelfCheck.runAndExit()
        }
        // ponytail: debug harness for manual/CI runtime verification of the real WhisperKit
        // pipeline; see DebugTranscribe.swift.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--transcribe"),
           CommandLine.arguments.indices.contains(flagIndex + 1) {
            DebugTranscribe.runAndExit(path: CommandLine.arguments[flagIndex + 1])
        }
        // ponytail: debug harness for exercising the live-mic AVAudioEngine path (as opposed to
        // --transcribe, which loads a file); see DebugRecordTest.swift and CONTEXT.md live-mic
        // silence investigation.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--record-test") {
            let seconds = CommandLine.arguments.indices.contains(flagIndex + 1)
                ? Double(CommandLine.arguments[flagIndex + 1]) ?? 4
                : 4
            DebugRecordTest.runAndExit(seconds: seconds)
        }
        // Triggers the system Accessibility prompt on first launch if not already granted
        // (a no-op, no dialog, if already trusted or already declined once).
        Permissions.requestAccessibility()
        // Same idea for Microphone: primes the TCC prompt at launch so a first-time user isn't
        // met with a silent capture from `.notDetermined` status the first time they hold PTT.
        // No-op if already determined (granted or denied). See live-mic silence root cause H1.
        AppCoordinator.shared.primeMicrophonePermission()
        if AppSettings.shared.sttEngine == .whisperKit {
            Task { await AppCoordinator.shared.whisperEngine.preload() }
        }
        // One unified entry point: creates the tap, or (on failure) starts the 2s retry poll
        // and status text — the same path also used by app activation and hotkey reassignment.
        AppCoordinator.shared.ensureHotKeyListening()
    }

    var body: some Scene {
        MenuBarExtra("FreeTalker", systemImage: "waveform") {
            MenuBarContentView()
        }

        Window("Library", id: "library") {
            LibraryView()
        }

        Window("Settings", id: "settings") {
            SettingsView()
        }
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

            Button("Library…") { openWindow(id: "library") }
            Button("Settings…") { openWindow(id: "settings") }

            Divider()

            Button("Quit FreeTalker") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .onAppear { accessibilityTrusted = Permissions.isAccessibilityTrusted() }
    }
}
