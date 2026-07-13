import SwiftUI

struct SnippetDraft: Equatable {
    var name = ""
    var triggersText = ""
    var expansion = ""

    var validatedTriggers: [String] {
        triggersText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !SnippetStore.normalizeTrigger($0).isEmpty }
    }

    var validationMessage: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Name is required."
        }
        let triggers = validatedTriggers
        guard !triggers.isEmpty else { return "Add at least one trigger phrase." }
        let normalized = triggers.map(SnippetStore.normalizeTrigger)
        guard Set(normalized).count == normalized.count else {
            return "Trigger phrases must be unique after normalization."
        }
        guard !expansion.isEmpty else { return "Expansion is required." }
        return nil
    }

    init(name: String = "", triggersText: String = "", expansion: String = "") {
        self.name = name
        self.triggersText = triggersText
        self.expansion = expansion
    }

    init(snippet: Snippet) {
        self.init(name: snippet.name, triggersText: snippet.triggers.joined(separator: "\n"), expansion: snippet.expansion)
    }
}

enum SnippetEditorPresentation {
    static func message(for error: SnippetStoreError) -> String {
        switch error {
        case .emptyTrigger: "Add at least one trigger phrase."
        case .duplicateTrigger(let trigger): "The normalized trigger “\(trigger)” is already used. Edit conflicting legacy snippets to resolve the ambiguity."
        case .duplicateName: "A snippet with this name already exists."
        case .notFound: "This snippet no longer exists. Reload and try again."
        case .corruptData(let detail): "Snippet data is invalid: \(detail)"
        }
    }
}

struct SnippetStoreAvailabilityPresentation: Equatable {
    let message: String
    let showsRetry: Bool

    static func failure(_ detail: String) -> Self {
        Self(
            message: "The local snippet storage is unavailable: \(detail). Check that FreeTalker can write to Application Support, then retry.",
            showsRetry: true
        )
    }
}

struct SnippetsSettingsView: View {
    let store: SnippetStore?
    let initializationError: String?
    let retry: () -> Void
    @State private var snippets: [Snippet] = []
    @State private var selectedID: String?
    @State private var draft = SnippetDraft()
    @State private var errorMessage: String?
    @State private var pendingDelete: Snippet?

    init(store: SnippetStore?, initializationError: String? = nil, retry: @escaping () -> Void = {}) {
        self.store = store
        self.initializationError = initializationError
        self.retry = retry
    }

    var body: some View {
        SettingsEditorPage(title: "Snippets", subtitle: "Voice Edit shortcuts that replace selected text") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Select text, then say a trigger phrase during Voice Edit — it's replaced with the expansion verbatim, no AI rewrite. Anything else falls through to the normal AI edit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let initializationError {
                    let availability = SnippetStoreAvailabilityPresentation.failure(initializationError)
                    Label(availability.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    if availability.showsRetry {
                        Button("Retry local snippet storage", action: retry)
                    }
                }

                HSplitView {
                    VStack(alignment: .leading) {
                        List(selection: $selectedID) {
                            ForEach(snippets) { snippet in Text(snippet.name).tag(snippet.id as String?) }
                        }
                        HStack {
                            Button("New snippet", systemImage: "plus") { createDraft() }
                            Button("Delete", systemImage: "trash") {
                                pendingDelete = snippets.first { $0.id == selectedID }
                            }
                            .disabled(selectedID == nil)
                        }
                    }
                    .frame(minWidth: 180)

                    // A plain VStack, not a Form: Form collapses a single labeled field into a
                    // cramped label column against the HSplitView divider (see TemplateEditor
                    // in SettingsView.swift for the same pattern and rationale).
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Snippet name")
                        Text("Trigger phrases (one per line)").font(.headline)
                        TextEditor(text: $draft.triggersText)
                            .frame(minHeight: 90)
                            .accessibilityLabel("Snippet trigger phrases")
                        Text("Expansion").font(.headline)
                        TextEditor(text: $draft.expansion)
                            .frame(minHeight: 150)
                            .accessibilityLabel("Snippet expansion")
                        if let validationMessage = draft.validationMessage {
                            Text(validationMessage).font(.caption).foregroundStyle(.red)
                        }
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                        HStack {
                            Spacer()
                            Button("Save") { save() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(draft.validationMessage != nil)
                        }
                    }
                    .padding()
                    .frame(minWidth: 320)
                }
                .disabled(store == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .task { await reload() }
        .onChange(of: selectedID) { _, id in
            guard let snippet = snippets.first(where: { $0.id == id }) else { return }
            draft = SnippetDraft(snippet: snippet)
            errorMessage = nil
        }
        .confirmationDialog("Delete snippet?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete snippet", role: .destructive) { deletePending() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the snippet and all of its trigger phrases from this Mac.")
        }
    }

    private func createDraft() {
        selectedID = nil
        draft = SnippetDraft()
        errorMessage = nil
    }

    private func reload(select id: String? = nil) async {
        guard let store else { return }
        do {
            snippets = try await store.snippets()
            if let id { selectedID = id }
        } catch {
            errorMessage = "Could not load snippets."
        }
    }

    private func save() {
        guard draft.validationMessage == nil, let store else { return }
        let id = selectedID
        let draft = draft
        Task {
            do {
                let saved: Snippet
                if let id {
                    saved = try await store.update(
                        id: id, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                        triggers: draft.validatedTriggers, expansion: draft.expansion
                    )
                } else {
                    saved = try await store.create(
                        name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                        triggers: draft.validatedTriggers, expansion: draft.expansion
                    )
                }
                errorMessage = nil
                await reload(select: saved.id)
            } catch let error as SnippetStoreError {
                errorMessage = SnippetEditorPresentation.message(for: error)
            } catch {
                errorMessage = "Could not save the snippet."
            }
        }
    }

    private func deletePending() {
        guard let snippet = pendingDelete, let store else { return }
        pendingDelete = nil
        Task {
            do {
                try await store.delete(id: snippet.id)
                createDraft()
                await reload()
            } catch let error as SnippetStoreError {
                errorMessage = SnippetEditorPresentation.message(for: error)
            } catch {
                errorMessage = "Could not delete the snippet."
            }
        }
    }
}
