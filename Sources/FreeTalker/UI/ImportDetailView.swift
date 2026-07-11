import AppKit
import SwiftUI

struct ImportDetailView: View {
    @ObservedObject var store: JobLibraryStore
    let jobID: UUID
    @State private var detail: MediaImportDetail?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var renameSpeakerID: String?
    @State private var pendingDelete = false

    var body: some View {
        Group {
            if loading { ProgressView("Loading transcript…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let detail { content(detail) }
            else { ContentUnavailableView("Transcript unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage ?? "Try selecting the import again.")) }
        }
        .task(id: jobID) { await reload() }
        .onReceive(store.objectWillChange) { _ in Task { await reload() } }
        .sheet(isPresented: Binding(get: { renameSpeakerID != nil }, set: { if !$0 { renameSpeakerID = nil } })) {
            let speakerID = renameSpeakerID ?? ""
            let ids = detail?.speakerIDs ?? []
            let ordinal = (ids.firstIndex(of: speakerID) ?? 0) + 1
            SpeakerRenameView(
                currentName: detail?.names[speakerID] ?? "",
                fallbackName: "Speaker \(ordinal)"
            ) { name in
                Task {
                    do { try await store.renameSpeaker(jobID: jobID, speakerID: speakerID, name: name); await reload() }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("Delete this import?", isPresented: $pendingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteImport() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes FreeTalker’s derived audio, transcript, and speaker data. The original source file is never deleted.")
        }
        .alert("Import Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func content(_ detail: MediaImportDetail) -> some View {
        let actions = MediaImportPresentation.actions(state: detail.job.state, transcriptReady: detail.transcriptReady)
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: detail.job.source.reference).lastPathComponent).font(.title3.weight(.semibold))
                    Text(MediaImportPresentation.localOnlyMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if actions.contains(.cancel) { Button("Cancel", role: .destructive) { Task { await cancel() } } }
                if actions.contains(.retry) || actions.contains(.retrySpeakerSeparation) {
                    Button(actions.contains(.retrySpeakerSeparation) ? "Retry Speaker Separation" : "Retry") { Task { await retry() } }
                }
                if actions.contains(.export) { exportMenu(detail) }
                if actions.contains(.delete) { Button("Delete…", role: .destructive) { pendingDelete = true } }
            }
            .padding()
            Divider()
            if detail.transcriptReady {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(detail.attributedTranscript.enumerated()), id: \.offset) { _, segment in
                            transcriptSegment(segment, detail: detail)
                        }
                    }.padding()
                }
            } else if case .failed(let failure) = detail.job.state {
                ContentUnavailableView("Import failed", systemImage: "exclamationmark.triangle", description: Text(failure.message))
            } else {
                ProgressView("Preparing transcript…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func transcriptSegment(_ segment: AttributedTranscriptSegment, detail: MediaImportDetail) -> some View {
        let id = segment.speakerID
        let ordinal = id.flatMap { detail.speakerIDs.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let label = id.map { MediaImportPresentation.displayName(speakerID: $0, names: detail.names, ordinal: ordinal) } ?? "Unknown Speaker"
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(label) { renameSpeakerID = id }.buttonStyle(.plain).font(.headline).disabled(id == nil)
                Spacer()
                Text(Self.time(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(Self.time(segment.start)), \(segment.text)")
    }

    private func exportMenu(_ detail: MediaImportDetail) -> some View {
        Menu("Export") {
            Button("Plain Text…") { export(detail, format: .plainText) }
            Button("Markdown…") { export(detail, format: .markdown) }
            Button("SRT Subtitles…") { export(detail, format: .srt) }
            Button("WebVTT Subtitles…") { export(detail, format: .vtt) }
        }
    }

    private func export(_ detail: MediaImportDetail, format: TranscriptFormat) {
        guard detail.transcriptReady else { return }
        let ext = switch format { case .plainText: "txt"; case .markdown: "md"; case .srt: "srt"; case .vtt: "vtt" }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.init(filenameExtension: ext)!]
        panel.nameFieldStringValue = URL(fileURLWithPath: detail.job.source.reference).deletingPathExtension().lastPathComponent + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let output = TranscriptExporter().export(detail.attributedTranscript, format: format, speakerNames: detail.exportNames)
            try output.write(to: url, atomically: true, encoding: .utf8)
        } catch { errorMessage = "Could not save the transcript: \(error.localizedDescription)" }
    }

    @MainActor private func reload() async {
        loading = detail == nil
        do { detail = try await store.importDetail(id: jobID); errorMessage = nil }
        catch { detail = nil; errorMessage = error.localizedDescription }
        loading = false
    }
    @MainActor private func cancel() async { do { try await store.cancelImport(id: jobID) } catch { errorMessage = error.localizedDescription } }
    @MainActor private func retry() async { do { try await store.retryImport(id: jobID) } catch { errorMessage = error.localizedDescription } }
    @MainActor private func deleteImport() async { do { try await store.deleteImport(id: jobID) } catch { errorMessage = error.localizedDescription } }
    private static func time(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
