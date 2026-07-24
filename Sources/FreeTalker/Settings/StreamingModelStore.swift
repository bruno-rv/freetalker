import FluidAudio
import Foundation

/// Download/delete state for the single Streaming ASR model (Parakeet EOU 120M, 160ms — see
/// `FluidAudioStreamingEngine`), presented in Settings with the exact same `SpeechModelStore.Phase`
/// state machine and `SpeechModelStore.canStartManualDownload`/`canDelete` rules WhisperKit models
/// use — reusing that pattern rather than inventing a second one (BRAINSTORM_STREAMING_ASR.md
/// item 7). There is only ever one model here (no variant picker), so this is a much smaller type
/// than `SpeechModelStore`, but it shares the same `Phase` shape so `SettingsView` can render it
/// with the same status-text logic (`SpeechModelRowPresentation.phaseText`-equivalent below).
@MainActor
final class StreamingModelStore: ObservableObject {
    static let shared = StreamingModelStore()

    @Published private(set) var phase: SpeechModelStore.Phase = .notDownloaded
    @Published private(set) var sizeBytes: Int64?

    private let modelDirectory: URL
    let engine: FluidAudioStreamingEngine

    init(
        modelsRoot: URL = FreeTalkerPaths.fluidAudioModels,
        engine: FluidAudioStreamingEngine? = nil
    ) {
        self.modelDirectory = modelsRoot.appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)
        self.engine = engine ?? FluidAudioStreamingEngine(modelsDirectory: modelsRoot)
        Task { await refresh() }
    }

    nonisolated static func inspect(_ directory: URL) -> SpeechModelStore.Inspection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return SpeechModelStore.Inspection(downloaded: false, sizeBytes: nil)
        }
        let complete = ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard complete else { return SpeechModelStore.Inspection(downloaded: false, sizeBytes: nil) }
        return SpeechModelStore.Inspection(downloaded: true, sizeBytes: SpeechModelStore.recursiveSize(of: directory))
    }

    func refresh() async {
        switch phase {
        case .downloading, .busy: return
        case .notDownloaded, .downloaded, .failed: break
        }
        let directory = modelDirectory
        let inspection = await Task.detached { Self.inspect(directory) }.value
        phase = inspection.downloaded ? .downloaded : .notDownloaded
        sizeBytes = inspection.sizeBytes
    }

    func download() async {
        guard SpeechModelStore.canStartManualDownload(phase: phase, reserved: false) else { return }
        phase = .downloading(0)
        do {
            try await engine.prepare { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(fraction)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await refresh()
    }

    func delete() async throws {
        guard SpeechModelStore.canDelete(phase: phase, active: false) else { return }
        phase = .busy(reloadTarget: "parakeet-eou-160ms")
        let directory = modelDirectory
        do {
            try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
            await refresh()
        } catch {
            await refresh()
            throw error
        }
    }
}
