import SwiftUI

struct VoiceEditPreviewView: View {
    @ObservedObject var coordinator: VoiceEditCoordinator
    let onDismiss: () -> Void
    @State private var confirmationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !coordinator.snippetChoices.isEmpty {
                Text("Choose a snippet").font(.headline)
                ForEach(coordinator.snippetChoices) { snippet in
                    Button(snippet.name) { coordinator.chooseSnippet(id: snippet.id) }
                }
            } else if let preview = coordinator.preview {
                Text("Preview edit").font(.headline)
                Text(preview.result).textSelection(.enabled)
                HStack {
                    Button("Cancel", role: .cancel) { coordinator.cancel(); onDismiss() }
                    Button("Copy") { coordinator.copyResult(); onDismiss() }
                    Spacer()
                    Button("Replace") { confirm() }.keyboardShortcut(.defaultAction)
                }
            } else if coordinator.error != nil {
                Text("The edit could not be prepared.")
                Button("Close") { coordinator.cancel(); onDismiss() }
            } else {
                ProgressView("Preparing edit…")
            }
        }
        .padding(20)
        .frame(width: 440)
        .alert("Selection changed", isPresented: Binding(
            get: { confirmationError != nil },
            set: { if !$0 { confirmationError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(confirmationError ?? "") }
    }

    private func confirm() {
        do {
            try coordinator.confirm()
            onDismiss()
        } catch {
            confirmationError = "The selected text changed. Review the target and try again."
        }
    }
}
