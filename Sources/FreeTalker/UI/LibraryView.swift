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
    @State private var actionError: String?
    @StateObject private var translation = LibraryTranslationController()

    private var translationPresentation: LibraryTranslationPresentation {
        LibraryTranslationPresentation(availability: translation.availability)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                translationControls
                labeledText(selectionLabel, translation.displayedText(for: dictation))

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

                    if case .variant = translation.selection {
                        Button("Regenerate…") {
                            guard case .variant(let target) = translation.selection else { return }
                            translation.translate(entry: dictation, to: target)
                        }
                        .disabled(translation.isTranslating || !translationPresentation.isEnabled)
                    }

                    Spacer()

                    Button("Delete…", role: .destructive, action: onDeleteRequested)
                }
            }
            .padding()
        }
        .task(id: dictation.id) {
            translation.selectEntry(id: dictation.id)
        }
        .confirmationDialog(
            "Replace saved \(translation.pendingReplacementTarget?.promptName ?? "translation") translation?",
            isPresented: Binding(
                get: { translation.pendingReplacementTarget != nil },
                set: { if !$0 { translation.dismissReplacement() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace Translation", role: .destructive) { translation.confirmReplacement() }
            Button("Cancel", role: .cancel) { translation.dismissReplacement() }
        } message: {
            Text("This replaces the saved translation. The original Library entry is not changed.")
        }
        .alert(
            "Translation Failed",
            isPresented: Binding(
                get: { translation.errorMessage != nil },
                set: { if !$0 { translation.dismissError() } }
            )
        ) {
            if translation.canRetry {
                Button("Retry") { translation.retry(entry: dictation) }
            }
            Button("OK", role: .cancel) { translation.dismissError() }
        } message: {
            Text(translation.errorMessage ?? "")
        }
        .alert(
            "Library Action Failed",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var selectionLabel: String {
        switch translation.selection {
        case .original: "Original"
        case .variant(let target): target.promptName
        }
    }

    private var translationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Version", selection: Binding(
                    get: { translation.selection },
                    set: { translation.select($0) }
                )) {
                    Text("Original").tag(LibraryTranslationController.Selection.original)
                    ForEach(translation.variants, id: \.target.rawValue) { variant in
                        Text(variant.target.promptName)
                            .tag(LibraryTranslationController.Selection.variant(variant.target))
                    }
                }
                .pickerStyle(.menu)

                translateMenu

                Button {
                    do {
                        try translation.copyDisplayedText(for: dictation)
                    } catch {
                        actionError = error.localizedDescription
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                if translation.isTranslating {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { translation.cancel() }
                }
            }

            Text(translationPresentation.privacyDisclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var translateMenu: some View {
        let menu = Menu("Translate…") {
            ForEach(translationPresentation.targets, id: \.rawValue) { target in
                Button(target.promptName) {
                    translation.translate(entry: dictation, to: target)
                }
            }
        }
        .disabled(!translationPresentation.isEnabled || translation.isTranslating)

        if !translationPresentation.isEnabled,
           let tooltip = translationPresentation.tooltip,
           let accessibilityHelp = translationPresentation.accessibilityHelp {
            HStack { menu }
                .help(tooltip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Translate Library entry")
                .accessibilityValue("Unavailable")
                .accessibilityHint(accessibilityHelp)
        } else {
            menu
        }
    }

    private func labeledText(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.headline)
                Spacer()
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
