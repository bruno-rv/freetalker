import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FreeTalker

@Suite struct MediaImportServiceTests {
    @Test func allowlistAcceptsOnlyPlannedAudioAndVideoTypes() {
        for name in ["clip.wav", "clip.m4a", "clip.mp3", "clip.mp4", "clip.mov"] {
            #expect(MediaImportService.isSupported(URL(fileURLWithPath: name)))
        }
        for name in ["clip.aiff", "clip.flac", "clip.txt", "clip", "clip.wav.exe"] {
            #expect(!MediaImportService.isSupported(URL(fileURLWithPath: name)))
        }
    }

    @Test func createJobPreservesBookmarkThroughActorStore() async throws {
        let source = URL(fileURLWithPath: "/outside/tone.wav")
        let access = BookmarkProbe(resolvedURL: source)
        let store = MediaStoreProbe()
        let service = MediaImportService(store: store, bookmarkAccess: access, mediaProbe: MediaProbe(result: .success), clock: { Date(timeIntervalSince1970: 42) })

        let id = try await service.createJob(for: source)

        #expect(await store.created?.id == id)
        #expect(await store.created?.source == JobSource(reference: source.path, bookmark: Data("bookmark".utf8)))
        #expect(await access.created == [source])
        #expect(await access.started == [source])
        #expect(await access.stopped == [source])
    }

    @Test func rejectsUnsupportedTypeBeforeBookmarkOrPersistence() async {
        let access = BookmarkProbe(resolvedURL: URL(fileURLWithPath: "/tmp/a.txt"))
        let store = MediaStoreProbe()
        let service = MediaImportService(store: store, bookmarkAccess: access, mediaProbe: MediaProbe(result: .success))

        await #expect(throws: MediaImportError.unsupportedType) {
            try await service.createJob(for: URL(fileURLWithPath: "/tmp/a.txt"))
        }
        #expect(await access.created.isEmpty)
        #expect(await access.started.isEmpty)
        #expect(await access.stopped.isEmpty)
        #expect(await store.created == nil)
    }

    @Test func createJobRejectsDisguisedNonMediaBeforeBookmarkOrPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("not-really.wav")
        try Data("arbitrary bytes".utf8).write(to: source)
        let access = BookmarkProbe(resolvedURL: source)
        let store = MediaStoreProbe()
        let service = MediaImportService(store: store, bookmarkAccess: access)

        await #expect(throws: MediaImportError.invalidMedia) {
            try await service.createJob(for: source)
        }
        #expect(await access.created.isEmpty)
        #expect(await access.started == [source])
        #expect(await access.stopped == [source])
        #expect(await store.created == nil)
    }

    @Test func createJobAcceptsRealMediaRenamedToAnotherAllowedExtension() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("renamed.wav")
        try FileManager.default.copyItem(
            at: Bundle.module.url(forResource: "two-tone", withExtension: "m4a", subdirectory: "Fixtures")!,
            to: source
        )
        let access = BookmarkProbe(resolvedURL: source)
        let store = MediaStoreProbe()
        let service = MediaImportService(store: store, bookmarkAccess: access)

        _ = try await service.createJob(for: source)

        #expect(await access.created == [source])
        #expect(await access.started == [source])
        #expect(await access.stopped == [source])
        #expect(await store.created != nil)
    }

    @Test func createJobRejectsSilentVideoBeforeBookmarkOrPersistence() async throws {
        let source = Bundle.module.url(forResource: "silent-video", withExtension: "mov", subdirectory: "Fixtures")!
        let access = BookmarkProbe(resolvedURL: source)
        let store = MediaStoreProbe()
        let service = MediaImportService(store: store, bookmarkAccess: access)

        await #expect(throws: MediaImportError.noAudioTrack) {
            try await service.createJob(for: source)
        }
        #expect(await access.created.isEmpty)
        #expect(await access.started == [source])
        #expect(await access.stopped == [source])
        #expect(await store.created == nil)
    }

    @Test func injectedProbeFailurePreventsBookmarkAndJob() async {
        let source = URL(fileURLWithPath: "/outside/tone.wav")
        let access = BookmarkProbe(resolvedURL: source)
        let store = MediaStoreProbe()
        let service = MediaImportService(store: store, bookmarkAccess: access, mediaProbe: MediaProbe(result: .invalid))

        await #expect(throws: MediaImportError.invalidMedia) {
            try await service.createJob(for: source)
        }
        #expect(await access.created.isEmpty)
        #expect(await access.started == [source])
        #expect(await access.stopped == [source])
        #expect(await store.created == nil)
    }

    @Test func resolvedAccessIsBalancedOnSuccessErrorAndCancellation() async throws {
        for outcome in DecodeProbe.Outcome.allCases {
            let source = URL(fileURLWithPath: "/resolved/source.wav")
            let access = BookmarkProbe(resolvedURL: source)
            let store = MediaStoreProbe()
            let job = await store.seed(source: .init(reference: "/old/source.wav", bookmark: Data("bookmark".utf8)))
            let decoder = DecodeProbe(outcome: outcome)
            let service = MediaImportService(store: store, bookmarkAccess: access, decoder: decoder)

            if outcome == .success {
                try await service.decode(jobID: job.id, destination: URL(fileURLWithPath: "/tmp/out.wav"), cancellation: CancellationToken()) { _ in }
            } else {
                await #expect(throws: (any Error).self) {
                    try await service.decode(jobID: job.id, destination: URL(fileURLWithPath: "/tmp/out.wav"), cancellation: CancellationToken()) { _ in }
                }
            }

            #expect(await access.resolved == [Data("bookmark".utf8)])
            #expect(await access.started == [source])
            #expect(await access.stopped == [source])
        }
    }

    @Test func staleBookmarkIsRejectedWithoutStartingAccess() async {
        let access = BookmarkProbe(resolvedURL: URL(fileURLWithPath: "/resolved/source.wav"), stale: true)
        let store = MediaStoreProbe()
        let job = await store.seed(source: .init(reference: "/old/source.wav", bookmark: Data("bookmark".utf8)))
        let service = MediaImportService(store: store, bookmarkAccess: access, decoder: DecodeProbe(outcome: .success))

        await #expect(throws: MediaImportError.staleBookmark) {
            try await service.decode(jobID: job.id, destination: URL(fileURLWithPath: "/tmp/out.wav"), cancellation: CancellationToken()) { _ in }
        }
        #expect(await access.started.isEmpty)
        #expect(await access.stopped.isEmpty)
    }

    @Test func decoderWritesNormalizedDiskBackedWaveAndPreservesSource() async throws {
        let fixture = try MediaFixture()
        let sourceBytes = try Data(contentsOf: fixture.tone)
        let progress = ProgressProbe()

        try await AVAudioDecoder().decode(source: fixture.tone, destination: fixture.output, progress: { value in
            progress.append(value)
        }, cancellation: CancellationToken())

        #expect(try Data(contentsOf: fixture.tone) == sourceBytes)
        let output = try AVAudioFile(forReading: fixture.output)
        #expect(output.fileFormat.sampleRate == 16_000)
        #expect(output.fileFormat.channelCount == 1)
        #expect(abs(output.length - 1_920) <= 1)
        let values = progress.values
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values == values.sorted())
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathExtension("partial").path))
    }

    @Test func decoderDrainsNonIntegerResamplerTail() async throws {
        let fixture = try MediaFixture(duration: 0.101)

        try await AVAudioDecoder().decode(source: fixture.tone, destination: fixture.output, progress: { _ in }, cancellation: CancellationToken())

        let output = try AVAudioFile(forReading: fixture.output)
        let inputFrames: Double = 4_454
        let expected = Int64((inputFrames * 16_000 / 44_100).rounded())
        #expect(abs(output.length - expected) <= 1)
    }

    @Test func decoderStreamsCompressedAudioToNormalizedWave() async throws {
        let fixture = try MediaFixture()
        let source = Bundle.module.url(forResource: "two-tone", withExtension: "m4a", subdirectory: "Fixtures")!

        try await AVAudioDecoder().decode(
            source: source,
            destination: fixture.output,
            progress: { _ in },
            cancellation: CancellationToken()
        )

        let output = try AVAudioFile(forReading: fixture.output)
        #expect(output.fileFormat.sampleRate == 16_000)
        #expect(output.fileFormat.channelCount == 1)
        #expect(output.length > 0)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func decoderRemovesPartialAndDestinationOnCancellation() async throws {
        let fixture = try MediaFixture(duration: 2)
        let token = CancellationToken()

        await #expect(throws: CancellationError.self) {
            try await AVAudioDecoder().decode(source: fixture.tone, destination: fixture.output, progress: { value in
                if value > 0 { token.cancel() }
            }, cancellation: token)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathExtension("partial").path))
        #expect(FileManager.default.fileExists(atPath: fixture.tone.path))
    }

    @Test func videoWithoutAudioReportsTruthfulErrorAndLeavesNoOutput() async throws {
        let fixture = try MediaFixture()
        try await fixture.makeSilentVideo()

        await #expect(throws: MediaImportError.noAudioTrack) {
            try await AVAudioDecoder().decode(source: fixture.silentVideo, destination: fixture.output, progress: { _ in }, cancellation: CancellationToken())
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
        #expect(FileManager.default.fileExists(atPath: fixture.silentVideo.path))
    }

    @Test func generatedVideoWithAudioImportsAndExtractsNormalizedFramesWithoutChangingSource() async throws {
        let fixture = try MediaFixture()
        let video = try await fixture.makeVideoWithAudio()
        let sourceBytes = try Data(contentsOf: video)
        let access = BookmarkProbe(resolvedURL: video)
        let store = MediaStoreProbe()
        let service = MediaImportService(store: store, bookmarkAccess: access)

        let id = try await service.createJob(for: video)
        try await service.decode(jobID: id, destination: fixture.output, cancellation: CancellationToken()) { _ in }

        let output = try AVAudioFile(forReading: fixture.output)
        #expect(output.fileFormat.sampleRate == 16_000)
        #expect(output.fileFormat.channelCount == 1)
        #expect(output.length > 0)
        #expect(try Data(contentsOf: video) == sourceBytes)
    }
}

private actor MediaStoreProbe: MediaImportJobStoring {
    struct Created { let id: UUID; let source: JobSource }
    var created: Created?
    private var jobs: [UUID: TranscriptionJob] = [:]

    func create(kind: JobKind, source: JobSource, now: Date) throws -> TranscriptionJob {
        let job = TranscriptionJob(id: UUID(), kind: kind, source: source, state: .queued, progress: 0, createdAt: now, updatedAt: now, startedAt: nil, completedAt: nil, expiresAt: nil, result: nil, needsSourceCleanup: false, sourceCleanupError: nil)
        jobs[job.id] = job
        created = .init(id: job.id, source: source)
        return job
    }

    func job(id: UUID) throws -> TranscriptionJob? { jobs[id] }

    func seed(source: JobSource) -> TranscriptionJob {
        let now = Date()
        let job = TranscriptionJob(id: UUID(), kind: .mediaImport, source: source, state: .queued, progress: 0, createdAt: now, updatedAt: now, startedAt: nil, completedAt: nil, expiresAt: nil, result: nil, needsSourceCleanup: false, sourceCleanupError: nil)
        jobs[job.id] = job
        return job
    }
}

private actor BookmarkProbe: SecurityScopedBookmarkAccessing {
    let resolvedURL: URL
    let stale: Bool
    var created: [URL] = []
    var resolved: [Data] = []
    var started: [URL] = []
    var stopped: [URL] = []

    init(resolvedURL: URL, stale: Bool = false) { self.resolvedURL = resolvedURL; self.stale = stale }
    func createBookmark(for url: URL) throws -> Data { created.append(url); return Data("bookmark".utf8) }
    func resolveBookmark(_ data: Data) throws -> ResolvedSecurityScopedURL { resolved.append(data); return .init(url: resolvedURL, isStale: stale) }
    func startAccessing(_ url: URL) -> Bool { started.append(url); return true }
    func stopAccessing(_ url: URL) { stopped.append(url) }
}

private actor DecodeProbe: MediaAudioDecoding {
    enum Outcome: CaseIterable { case success, failure, cancellation }
    let outcome: Outcome
    init(outcome: Outcome) { self.outcome = outcome }
    func decode(source: URL, destination: URL, progress: @Sendable (Double) -> Void, cancellation: CancellationToken) async throws {
        switch outcome {
        case .success: return
        case .failure: throw CocoaError(.fileReadCorruptFile)
        case .cancellation: throw CancellationError()
        }
    }
}

private struct MediaProbe: MediaAssetProbing {
    enum Result { case success, invalid }
    let result: Result
    func validateAudio(at url: URL) async throws {
        if result == .invalid { throw MediaImportError.invalidMedia }
    }
}

private final class MediaFixture: @unchecked Sendable {
    let directory: URL
    let tone: URL
    let output: URL
    let silentVideo: URL
    let videoWithAudio: URL

    init(duration: Double = 0.1) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tone = directory.appendingPathComponent("tone.wav")
        output = directory.appendingPathComponent("normalized.wav")
        silentVideo = directory.appendingPathComponent("silent-video.mov")
        videoWithAudio = directory.appendingPathComponent("video-with-audio.mov")
        if duration == 0.1 {
            try FileManager.default.copyItem(at: Bundle.module.url(forResource: "tone", withExtension: "wav", subdirectory: "Fixtures")!, to: tone)
        } else {
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            let file = try AVAudioFile(forWriting: tone, settings: format.settings)
            let frames = AVAudioFrameCount(44_100 * duration)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<2 { for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.1) * 0.1 } }
            try file.write(from: buffer)
        }
    }

    func makeSilentVideo() async throws {
        try FileManager.default.copyItem(
            at: Bundle.module.url(forResource: "silent-video", withExtension: "mov", subdirectory: "Fixtures")!,
            to: silentVideo
        )
    }

    func makeVideoWithAudio() async throws -> URL {
        let silent = Bundle.module.url(forResource: "silent-video", withExtension: "mov", subdirectory: "Fixtures")!
        let videoAsset = AVURLAsset(url: silent)
        let audioAsset = AVURLAsset(url: tone)
        let composition = AVMutableComposition()
        let videoSource = try #require(await videoAsset.loadTracks(withMediaType: .video).first)
        let audioSource = try #require(await audioAsset.loadTracks(withMediaType: .audio).first)
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let duration = CMTimeMinimum(videoDuration, audioDuration)
        let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(.init(start: .zero, duration: duration), of: videoSource, at: .zero)
        try audioTrack.insertTimeRange(.init(start: .zero, duration: duration), of: audioSource, at: .zero)
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        guard #available(macOS 15, *) else { throw CocoaError(.featureUnsupported) }
        try await exporter.export(to: videoWithAudio, as: .mov)
        return videoWithAudio
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}
