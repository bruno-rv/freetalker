import SwiftUI

struct RecoveryRetrySheet: View {
    let job: TranscriptionJob
    @ObservedObject var store: JobLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var language = ""
    @State private var template = ""
    @State private var speechModel = ""
    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Text("Try the saved audio again. Leave overrides unchanged to use your current settings.")
                .foregroundStyle(.secondary)
            DisclosureGroup("Overrides") {
                TextField("Language", text: $language, prompt: Text("Current setting"))
                TextField("Speech model", text: $speechModel, prompt: Text("Current model"))
                Picker("Template", selection: $template) {
                    Text("Current template").tag("")
                    ForEach(TemplateStore.shared.templates) { Text($0.name).tag($0.id) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(submitting ? "Queuing…" : "Retry") { submit() }
                    .keyboardShortcut(.defaultAction).disabled(submitting)
            }
        }
        .padding(20).frame(width: 420)
        .alert("Retry Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func submit() {
        submitting = true
        Task {
            do {
                try await store.retry(id: job.id, configuration: .init(language: nilIfEmpty(language), speechModel: nilIfEmpty(speechModel), template: nilIfEmpty(template)))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                submitting = false
            }
        }
    }

    private func nilIfEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }
}
