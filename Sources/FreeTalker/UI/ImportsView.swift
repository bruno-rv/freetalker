import SwiftUI
import UniformTypeIdentifiers

struct ImportsView: View {
    @ObservedObject var store: JobLibraryStore
    @ObservedObject private var coordinator = AppCoordinator.shared
    @State private var selectedID: UUID?
    @State private var choosingFile = false
    @State private var errorMessage: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                localOnlyBanner
                if store.importJobs.isEmpty {
                    ContentUnavailableView(
                        "No imports yet",
                        systemImage: "waveform.badge.plus",
                        description: Text("Choose or drop a WAV, M4A, MP3, MP4, or MOV file to transcribe it locally.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(store.importJobs, selection: $selectedID) { job in
                        ImportRow(job: job, transcriptionStatus: coordinator.engineStatusText).tag(job.id)
                    }
                }
                Divider()
                HStack {
                    Button("Choose Media…") { choosingFile = true }
                        .keyboardShortcut("o", modifiers: .command)
                    Spacer()
                    Text("You can also drop media here")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
            }
            .frame(minWidth: 280)
            .dropDestination(for: URL.self) { urls, _ in
                let eligible = urls.filter(MediaImportPresentation.acceptsDrop)
                guard !eligible.isEmpty else {
                    errorMessage = MediaImportError.unsupportedType.localizedDescription
                    return false
                }
                Task { for url in eligible { await importURL(url) } }
                return true
            }

            if let selectedID {
                ImportDetailView(store: store, jobID: selectedID)
            } else {
                ContentUnavailableView("Select an import", systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fileImporter(
            isPresented: $choosingFile,
            allowedContentTypes: Self.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): Task { for url in urls { await importURL(url) } }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Import Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .task { try? await store.refresh() }
    }

    private var localOnlyBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(MediaImportPresentation.localOnlyMessage, systemImage: "lock.shield.fill")
                .font(.callout.weight(.semibold))
            Text(MediaImportPresentation.videoExtractionMessage)
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.green.opacity(0.09))
        .accessibilityElement(children: .combine)
    }

    @MainActor private func importURL(_ url: URL) async {
        do { try await store.importMedia(url) }
        catch { errorMessage = error.localizedDescription }
    }

    private static let supportedTypes: [UTType] = ["wav", "m4a", "mp3", "mp4", "mov"].compactMap {
        UTType(filenameExtension: $0)
    }
}

private struct ImportRow: View {
    let job: TranscriptionJob
    let transcriptionStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(URL(fileURLWithPath: job.source.reference).lastPathComponent)
                .font(.callout.weight(.medium)).lineLimit(1)
            switch job.state {
            case .processing(let stage):
                let progress = MediaImportPresentation.progress(stage: stage, overall: job.progress)
                ProgressView(value: progress.fraction) {
                    Text(stage == .transcribing ? "\(progress.label) — \(transcriptionStatus)" : progress.label)
                }
                    .accessibilityValue(Text("\(Int(progress.fraction * 100)) percent"))
            case .queued: Label("Waiting", systemImage: "clock")
            case .ready: Label("Transcript ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .cancelled: Label("Cancelled — ready to retry", systemImage: "pause.circle")
            case .failed(let failure): Label(failure.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
