import AppKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var coordinator = AppCoordinator.shared
    @State private var selectedID: Int64?
    @State private var pendingDeleteID: Int64?
    @State private var showDeleteAllConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(store.dictations, selection: $selectedID) { dictation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dictation.refined.isEmpty ? dictation.transcript : dictation.refined)
                            .lineLimit(2)
                            .font(.callout)
                        HStack(spacing: 6) {
                            Text(dictation.templateName)
                            Text("·")
                            Text(dictation.language)
                            Text("·")
                            Text(dictation.timestamp, style: .date)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .tag(dictation.id)
                    .contextMenu {
                        Button("Delete…", role: .destructive) {
                            pendingDeleteID = dictation.id
                        }
                    }
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Delete All…", role: .destructive) {
                        showDeleteAllConfirm = true
                    }
                    .disabled(coordinator.isRecording || coordinator.isProcessing)
                }
                .padding(8)
            }
            .frame(minWidth: 260)

            if let selectedID, let dictation = store.dictations.first(where: { $0.id == selectedID }) {
                DictationDetailView(dictation: dictation, onDeleteRequested: { pendingDeleteID = dictation.id })
            } else {
                Text("Select a Dictation").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 480)
        .confirmationDialog(
            "Delete this Dictation?",
            isPresented: Binding(get: { pendingDeleteID != nil }, set: { if !$0 { pendingDeleteID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let id = pendingDeleteID else { return }
                pendingDeleteID = nil
                do {
                    try store.delete(id: id)
                    if selectedID == id { selectedID = nil }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("This cannot be undone. Re-processed copies of this Dictation, if any, are separate entries and remain.")
        }
        .confirmationDialog(
            "Delete All \(store.dictations.count) \(store.dictations.count == 1 ? "Entry" : "Entries")?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                // Re-checked here (not just via `.disabled` above) because a global hotkey can
                // start a dictation while this dialog sits open. See PLAN.md step 4.
                guard !coordinator.isRecording, !coordinator.isProcessing else {
                    errorMessage = "Can't delete — a dictation is in progress. Try again once it finishes."
                    return
                }
                do {
                    try store.deleteAll()
                    selectedID = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes all \(store.dictations.count) Library entries and any saved debug audio. This cannot be undone.")
        }
        .alert(
            "Library Error",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct DictationDetailView: View {
    let dictation: Dictation
    let onDeleteRequested: () -> Void
    @State private var reprocessing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                labeledText("Transcript", dictation.transcript)
                labeledText("Refined Output", dictation.refined)

                HStack {
                    Text("Template: \(dictation.templateName)")
                    Spacer()
                    Text("Engine: \(dictation.engine)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Menu(reprocessing ? "Re-processing…" : "Re-process with…") {
                        ForEach(TemplateStore.shared.templates) { template in
                            Button(template.name) {
                                reprocessing = true
                                Task {
                                    await AppCoordinator.shared.reprocess(dictation: dictation, with: template)
                                    reprocessing = false
                                }
                            }
                        }
                    }
                    .disabled(reprocessing)

                    Spacer()

                    Button("Delete…", role: .destructive, action: onDeleteRequested)
                }
            }
            .padding()
        }
    }

    private func labeledText(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            Text(text)
                .textSelection(.enabled)
                .font(.body)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
