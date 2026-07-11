import SwiftUI

struct VoiceEditPreviewView: View {
    @ObservedObject var coordinator: VoiceEditCoordinator
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
                Text(preview.result).textSelection(.enabled)
                HStack {
                    Button("Cancel", role: .cancel) { coordinator.cancel(); onDismiss() }
                    Button("Copy") { copyResult() }
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
        .alert("Voice Edit", isPresented: Binding(
            get: { coordinator.preview != nil && coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.dismissError() } }
        )) { Button("OK", role: .cancel) {} } message: { Text(coordinator.errorMessage ?? "") }
    }

    private func confirm() {
        do {
            try coordinator.confirm()
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
