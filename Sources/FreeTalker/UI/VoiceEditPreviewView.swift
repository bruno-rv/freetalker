import SwiftUI

enum VoiceEditPreviewAccessibility {
    static let originalLabel = "Original selected text"
    static let proposedLabel = "Proposed replacement text"
    static let replaceHint = "This revalidates the original target and replaces only if it is unchanged"
    static let copyHint = "Copies the proposed text and does not replace the selection"
}

struct VoiceEditPreviewWindowPresentation {
    let styleMask: NSWindow.StyleMask
    let becomesKeyOnlyIfNeeded: Bool
    let activatesApplication: Bool

    static func make() -> Self {
        Self(
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            becomesKeyOnlyIfNeeded: true,
            activatesApplication: false
        )
    }
}

struct VoiceEditPreviewView: View {
    @ObservedObject var coordinator: VoiceEditCoordinator
    /// Correction Loop signal B (BRAINSTORM_CORRECTION_LOOP.md): fired with (original, replaced)
    /// text ONLY after `coordinator.confirm()` actually succeeds — never on Cancel/Close, and
    /// never speculatively before the drift-checked replace has landed. `AppCoordinator` decides
    /// whether this edit was targeting a `RecentInsertion` at all; a plain manual-selection Voice
    /// Edit (the ordinary, pre-existing flow) passes a no-op here. Declared BEFORE `onDismiss` so
    /// existing/production call sites using trailing-closure syntax for `onDismiss` (the last
    /// parameter) are unaffected by this addition.
    var onReplaced: (String, String) -> Void = { _, _ in }
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !coordinator.snippetChoices.isEmpty {
                Text("Choose a snippet").font(.headline)
                ForEach(coordinator.snippetChoices) { snippet in
                    Button(snippet.name) { coordinator.chooseSnippet(id: snippet.id) }
                }
            } else if let preview = coordinator.preview {
                Text("Preview edit").font(.headline)
                Text("Instruction").font(.caption).foregroundStyle(.secondary)
                Text(coordinator.instruction)
                    .textSelection(.enabled)
                    .accessibilityLabel("Spoken edit instruction")
                Text("Original").font(.caption).foregroundStyle(.secondary)
                Text(coordinator.originalText)
                    .textSelection(.enabled)
                    .accessibilityLabel(VoiceEditPreviewAccessibility.originalLabel)
                Text("Proposed").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(preview.result).frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
                .accessibilityLabel(VoiceEditPreviewAccessibility.proposedLabel)
                HStack {
                    Button("Cancel", role: .cancel) { coordinator.cancel(); onDismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint("Closes the preview without changing the selection")
                    Button("Copy") { copyResult() }
                        .accessibilityHint(VoiceEditPreviewAccessibility.copyHint)
                    Spacer()
                    Button("Replace") { confirm() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!coordinator.canReplace)
                        .accessibilityLabel("Replace original selection")
                        .accessibilityHint(VoiceEditPreviewAccessibility.replaceHint)
                }
            } else if coordinator.error != nil {
                Text("The edit could not be prepared.")
                Button("Close") { coordinator.cancel(); onDismiss() }
            } else {
                ProgressView("Preparing edit…")
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 320)
        .alert("Voice Edit", isPresented: Binding(
            get: { coordinator.preview != nil && coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.dismissError() } }
        )) { Button("OK", role: .cancel) {} } message: { Text(coordinator.errorMessage ?? "") }
    }

    private func confirm() {
        guard let preview = coordinator.preview else { return }
        let original = coordinator.originalText
        do {
            try coordinator.confirm()
            onReplaced(original, preview.result)
            onDismiss()
        } catch {}
    }

    private func copyResult() {
        do {
            try coordinator.copyResult()
            onDismiss()
        } catch {}
    }
}
