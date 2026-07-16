import AppKit
import Combine
import SwiftUI

/// `nonactivatingPanel` per the HUD template (`HUDPanel.makePanel`), but unlike the HUD panel
/// this one's search field needs typing focus, so `canBecomeKey` is `true`; `canBecomeMain`
/// stays `false` — the app itself is never activated. See PLAN.md F3.3.
private final class HistoryQuickPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit's standard "Escape cancels" responder-chain hook — fires when Escape is pressed
    /// and no SwiftUI control (e.g. the search field) has already consumed it. See PLAN.md F3.4
    /// ("Esc closes").
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// One Dictation History Quick Panel row's presentation: latest-20 default list or search
/// result, refined-else-transcript (PLAN.md F3.3) — the same text `insertFromHistoryPanel`
/// inserts on row click.
struct HistoryPanelRow: Identifiable, Equatable {
    let id: Int64
    let displayText: String
    let timestamp: Date

    init(_ dictation: Dictation) {
        id = dictation.id
        displayText = Self.displayText(for: dictation)
        timestamp = dictation.timestamp
    }

    nonisolated static func displayText(for dictation: Dictation) -> String {
        dictation.refined.isEmpty ? dictation.transcript : dictation.refined
    }
}

/// Controller for the Dictation History Quick Panel (PLAN.md F3): a read-only `nonactivatingPanel`
/// listing the latest 20 dictations (or FTS/LIKE search results), opened from the fourth fixed
/// hotkey slot or the "Dictation History…" menu item, closed on row-insert or Esc, and gated on
/// the recording state machine both at open time and while already open.
@MainActor
final class HistoryPanelController: ObservableObject {
    static let shared = HistoryPanelController()

    nonisolated static let defaultListLimit = 20
    /// Search debounce (PLAN.md F3.3) — short enough to feel live, long enough that fast typing
    /// doesn't fire a search per keystroke.
    static let searchDebounceNanoseconds: UInt64 = 250_000_000

    @Published private(set) var query: String = ""
    @Published private(set) var rows: [HistoryPanelRow] = []

    private var dictationsByID: [Int64: Dictation] = [:]
    private var panel: HistoryQuickPanel?
    private let readActor = LibraryReadActor()
    private var searchTask: Task<Void, Never>?
    private var recordingGateCancellable: AnyCancellable?
    /// Bumped on every open/close (PLAN.md F3.3): a search result whose request generation no
    /// longer matches this is stale and is discarded before publishing, and in-flight work is
    /// cancelled on close.
    private(set) var generation = 0
    /// The `InsertionTarget` snapshotted synchronously before this panel opened (hotkey path) or
    /// tracked from the last non-FreeTalker frontmost app (menu path) — see PLAN.md F3.2.
    /// `Insertion.insert`'s own drift guard re-verifies it at row-click time.
    private var target: InsertionTarget?

    private init() {
        recordingGateCancellable = Publishers.CombineLatest(
            AppCoordinator.shared.$isRecording,
            AppCoordinator.shared.$isProcessing
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] isRecording, isProcessing in
            guard let self, Self.isBlockedByRecording(isRecording: isRecording, isProcessing: isProcessing) else { return }
            self.close()
        }
    }

    /// Recording gate (PLAN.md F3.4): true while an active recording/processing means the panel
    /// must refuse to open, or force-close if already open.
    nonisolated static func isBlockedByRecording(isRecording: Bool, isProcessing: Bool) -> Bool {
        isRecording || isProcessing
    }

    /// True when a completed search's request generation has been superseded by a newer
    /// open/close — its result must never populate a panel session it wasn't run for.
    nonisolated static func isStaleResult(requestGeneration: Int, currentGeneration: Int) -> Bool {
        requestGeneration != currentGeneration
    }

    func open(target: InsertionTarget?) {
        guard !Self.isBlockedByRecording(
            isRecording: AppCoordinator.shared.isRecording,
            isProcessing: AppCoordinator.shared.isProcessing
        ) else { return }
        generation += 1
        self.target = target
        query = ""
        rows = []
        dictationsByID = [:]
        runSearch(query: "")
        showPanel()
    }

    func close() {
        guard panel != nil else { return }
        generation += 1
        searchTask?.cancel()
        panel?.orderOut(nil)
    }

    func updateQuery(_ text: String) {
        query = text
        runSearch(query: text)
    }

    func selectRow(id: Int64) {
        guard let dictation = dictationsByID[id] else { return }
        AppCoordinator.shared.insertFromHistoryPanel(HistoryPanelRow.displayText(for: dictation), target: target)
        close()
    }

    private func runSearch(query: String) {
        let requestGeneration = generation
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            let results = (try? await self.readActor.search(query: query, limit: Self.defaultListLimit)) ?? []
            guard !Task.isCancelled,
                  !Self.isStaleResult(requestGeneration: requestGeneration, currentGeneration: self.generation)
            else { return }
            self.dictationsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
            self.rows = results.map(HistoryPanelRow.init)
        }
    }

    private func showPanel() {
        let hosting = NSHostingView(rootView: HistoryPanelContentView(
            controller: self,
            onSelect: { [weak self] id in self?.selectRow(id: id) },
            onClose: { [weak self] in self?.close() }
        ))
        let size = NSSize(width: 420, height: 360)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel: HistoryQuickPanel
        if let existing = self.panel {
            panel = existing
            panel.contentView = hosting
        } else {
            panel = HistoryQuickPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.contentView = hosting
            panel.onEscape = { [weak self] in self?.close() }
            self.panel = panel
        }
        if let screen = NSScreen.main {
            let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct HistoryPanelContentView: View {
    @ObservedObject var controller: HistoryPanelController
    let onSelect: (Int64) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dictation History")
                .font(.headline)
            TextField("Search", text: Binding(
                get: { controller.query },
                set: { controller.updateQuery($0) }
            ))
            .textFieldStyle(.roundedBorder)

            if controller.rows.isEmpty {
                Text("No dictations found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.rows) { row in
                            Button {
                                onSelect(row.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.displayText)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(row.timestamp, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 420, height: 360)
        .background(.regularMaterial)
        .onExitCommand(perform: onClose)
    }
}
