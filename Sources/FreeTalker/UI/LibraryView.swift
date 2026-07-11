import AppKit
import SwiftUI

struct LibraryView: View {
    private enum Section: String, CaseIterable { case dictations = "Dictations", recoveries = "Recoveries", imports = "Imports" }
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var coordinator = AppCoordinator.shared
    @State private var section: Section = .dictations
    @State private var selectedID: Int64?
    @State private var pendingDeleteID: Int64?
    @State private var showDeleteAllConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        // Unfiltered total, straight from the DB — NOT `store.dictations.count`, which is
        // filtered by an active search and would otherwise misreport e.g. "0 Entries" in the
        // Delete All dialog while the whole archive is about to be wiped. See Round 1 Codex
        // finding 1.
        VStack(spacing: 0) {
            Picker("Library section", selection: $section) {
                Text("Dictations").tag(Section.dictations)
                if let recoveryStore = coordinator.jobLibraryStore {
                    RecoveryPickerLabel(store: recoveryStore).tag(Section.recoveries)
                } else {
                    Text("Recoveries").tag(Section.recoveries)
                }
                Text("Imports").tag(Section.imports)
            }
            .pickerStyle(.segmented)
            .padding(8)

            switch section {
            case .dictations: dictationsView
            case .recoveries:
                if let recoveryStore = coordinator.jobLibraryStore { RecoveriesView(store: recoveryStore) }
                else { ContentUnavailableView("Recoveries Unavailable", systemImage: "exclamationmark.triangle") }
            case .imports:
                if let importStore = coordinator.jobLibraryStore { ImportsView(store: importStore) }
                else { ContentUnavailableView("Imports Unavailable", systemImage: "exclamationmark.triangle") }
            }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    private var dictationsView: some View {
        let deleteAllCount = store.totalCount()
        return HSplitView {
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
        // Same bug shape as Settings (Task 1): `.frame(width:height:)` is a FIXED frame — it
        // pins the content to exactly 720x480 regardless of what size the window scene actually
        // grants it, so maximizing the window stretches the window chrome only. A flexible frame
        // with min == the old fixed size and max == infinity keeps the same starting size but
        // lets the content track the window when resized/maximized.
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
            "Delete All \(deleteAllCount) \(deleteAllCount == 1 ? "Entry" : "Entries")?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
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
            Text("Permanently deletes all \(deleteAllCount) Library entries and any saved debug audio. This cannot be undone.")
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

private struct RecoveryPickerLabel: View {
    @ObservedObject var store: JobLibraryStore

    var body: some View {
        let count = RecoveryPresentation.badgeCount(store.recoveryJobs)
        let badge = RecoveryPresentation.badgeText(count: count)
        Text(badge.map { "Recoveries (\($0))" } ?? "Recoveries")
            .accessibilityLabel(count == 0 ? "Recoveries" : "Recoveries, \(count) needing attention")
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
