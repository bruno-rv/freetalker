import FluidAudio
import Foundation
import os
import Testing
import VoiceProfileCore
@testable import VoiceProfileFluidAudio

@Suite struct OfflineSpeakerRepresentationExtractorTests {
    @Test func mapsChunkEmbeddingsByFinalClusterWithDeterministicOrdering() throws {
        var first = Array(repeating: Float(0), count: 256)
        first[0] = 3; first[1] = 4
        var second = Array(repeating: Float(0), count: 256)
        second[2] = 1
        let result = DiarizationResult(
            segments: [
                .init(speakerId: "S2", embedding: [], startTimeSeconds: 2, endTimeSeconds: 4, qualityScore: 0),
                .init(speakerId: "S1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 2, qualityScore: 0)
            ],
            chunkEmbeddings: [
                .init(speakerId: "S2", chunkIndex: 1, speakerIndex: 0, startTimeSeconds: 2, endTimeSeconds: 4, embedding256: second),
                .init(speakerId: "S2", chunkIndex: 0, speakerIndex: 0, startTimeSeconds: 0, endTimeSeconds: 3, embedding256: first),
                .init(speakerId: "S1", chunkIndex: 2, speakerIndex: 0, startTimeSeconds: 4, endTimeSeconds: 5, embedding256: second)
            ]
        )

        let mapped = try OfflineSpeakerRepresentationExtractor.map(result, fingerprint: fixtureFingerprint)

        #expect(mapped.turns.map(\.speakerID) == ["S2", "S1"])
        #expect(mapped.speakers.map(\.speakerID) == ["S1", "S2"])
        #expect(mapped.speakers[1].samples.map(\.start) == [0, 2])
        #expect(mapped.speakers[1].cleanSpeechSeconds == 4)
        #expect(abs(mapped.speakers[1].samples[0].embedding.values[0] - 0.6) < 0.000_001)
        #expect(abs(mapped.speakers[1].samples[0].embedding.values[1] - 0.8) < 0.000_001)
    }

    @Test func dropsOnlyMalformedChunksAndTreatsUnavailableChunksAsEmpty() throws {
        let turn = TimedSpeakerSegment(
            speakerId: "S1", embedding: [], startTimeSeconds: 0, endTimeSeconds: 1, qualityScore: 0
        )
        let withoutChunks = try OfflineSpeakerRepresentationExtractor.map(
            .init(segments: [turn]), fingerprint: fixtureFingerprint
        )
        #expect(withoutChunks.turns.count == 1)
        #expect(withoutChunks.speakers.isEmpty)

        var valid = Array(repeating: Float(0), count: 256); valid[0] = 1
        var nan = valid; nan[1] = .nan
        var infinity = valid; infinity[1] = .infinity
        let chunks = [
            ChunkEmbedding(speakerId: "S1", chunkIndex: 0, speakerIndex: 0, startTimeSeconds: 0, endTimeSeconds: 1, embedding256: valid),
            ChunkEmbedding(speakerId: "S1", chunkIndex: 1, speakerIndex: 0, startTimeSeconds: 1, endTimeSeconds: 2, embedding256: [1]),
            ChunkEmbedding(speakerId: "S1", chunkIndex: 2, speakerIndex: 0, startTimeSeconds: 2, endTimeSeconds: 3, embedding256: nan),
            ChunkEmbedding(speakerId: "S1", chunkIndex: 3, speakerIndex: 0, startTimeSeconds: 3, endTimeSeconds: 4, embedding256: infinity),
            ChunkEmbedding(speakerId: "S1", chunkIndex: 4, speakerIndex: 0, startTimeSeconds: 4, endTimeSeconds: 5, embedding256: Array(repeating: 0, count: 256)),
            ChunkEmbedding(speakerId: "S1", chunkIndex: 5, speakerIndex: 0, startTimeSeconds: 6, endTimeSeconds: 5, embedding256: valid),
            ChunkEmbedding(speakerId: "", chunkIndex: 6, speakerIndex: 0, startTimeSeconds: 6, endTimeSeconds: 7, embedding256: valid)
        ]
        let withMalformed = try OfflineSpeakerRepresentationExtractor.map(
            .init(segments: [turn], chunkEmbeddings: chunks), fingerprint: fixtureFingerprint
        )
        #expect(withMalformed.turns.count == 1)
        #expect(withMalformed.speakers.count == 1)
        #expect(withMalformed.speakers[0].samples.count == 1)

        let emptyChunks = try OfflineSpeakerRepresentationExtractor.map(
            .init(segments: [turn], chunkEmbeddings: []), fingerprint: fixtureFingerprint
        )
        #expect(emptyChunks.speakers.isEmpty)
    }

    @Test func fingerprintHashesExactArtifactTreesAndConfiguration() throws {
        let root = try makeArtifactFixture(embedding: ["weights.bin": Data("embedding".utf8)], fbank: ["graph/data.bin": Data("fbank".utf8)])
        let fingerprint = try OfflineSpeakerRepresentationExtractor.fingerprint(modelsDirectory: root)
        #expect(fingerprint.provider == "FluidAudio")
        #expect(fingerprint.modelID == "speaker-diarization/Embedding.mlmodelc:embedding256")
        #expect(fingerprint.modelRevision == "tree-sha256-v1;Embedding.mlmodelc=81324d9b89b4f382e1a8eef199904113b62e0db3e48cc67bf163f5e86f900b02;FBank.mlmodelc=aaf5e4f40668cdeb5ca8867d121e16eecbb8ffb2098216c23e614848d7931173")
        #expect(fingerprint.preprocessingRevision == "sampleRate=16000;embeddingBatchSize=32;excludeOverlap=true;minSegmentDuration=1.0;skipStrategy=none;exposeChunkEmbeddings=true")
        #expect(fingerprint.dimension == 256)
    }

    @Test func fingerprintChangesWhenArtifactContentChanges() throws {
        let root = try makeArtifactFixture(embedding: ["weights.bin": Data("a".utf8)], fbank: ["graph.bin": Data("b".utf8)])
        let before = try OfflineSpeakerRepresentationExtractor.fingerprint(modelsDirectory: root)
        let file = artifactURL(root, "Embedding.mlmodelc").appendingPathComponent("weights.bin")
        try Data("updated".utf8).write(to: file)
        let after = try OfflineSpeakerRepresentationExtractor.fingerprint(modelsDirectory: root)
        #expect(before.modelRevision != after.modelRevision)
    }

    @Test(arguments: ["missing", "symlink"])
    func fingerprintRejectsMissingAndSymlinkArtifactsWithoutLeakingPaths(_ condition: String) throws {
        let root = try makeArtifactFixture(embedding: ["weights.bin": Data("a".utf8)], fbank: ["graph.bin": Data("b".utf8)])
        let embedding = artifactURL(root, "Embedding.mlmodelc")
        if condition == "missing" {
            try FileManager.default.removeItem(at: embedding)
        } else {
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: outside.appendingPathComponent("weights.bin"))
            try FileManager.default.removeItem(at: embedding)
            try FileManager.default.createSymbolicLink(
                at: embedding, withDestinationURL: outside
            )
        }
        do {
            _ = try OfflineSpeakerRepresentationExtractor.fingerprint(modelsDirectory: root)
            Issue.record("Expected artifact validation failure")
        } catch {
            #expect(!String(describing: error).contains(root.path))
            #expect(error is OfflineSpeakerRepresentationError)
        }
    }

    @Test func cancellationDrainsBackendSuppressesPublicationAndReleasesResource() async throws {
        let backend = SuspendedExtractionBackend()
        let progress = LockedDoubles()
        let completion = CompletionFlag()
        let extractor = OfflineSpeakerRepresentationExtractor(operation: { _, sink in
            try await backend.process(progress: sink)
        })
        let task = Task {
            defer { completion.mark() }
            return try await extractor.process(URL(fileURLWithPath: "/tmp/audio.wav")) { progress.append($0) }
        }
        await backend.waitUntilStarted()
        backend.report(0.25)
        task.cancel()
        backend.report(0.75)
        await Task.yield()
        #expect(!completion.value)
        #expect(progress.values == [0.25])
        #expect(!backend.released)

        backend.drain()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(completion.value)
        #expect(backend.released)
        #expect(progress.values == [0.25])
    }
}

private let fixtureFingerprint = EmbeddingModelFingerprint(
    provider: "test", modelID: "test", modelRevision: "test",
    preprocessingRevision: "test", dimension: 256
)

private func artifactURL(_ root: URL, _ name: String) -> URL {
    root.appendingPathComponent("speaker-diarization", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
}

private func makeArtifactFixture(embedding: [String: Data], fbank: [String: Data]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for (artifact, files) in [("Embedding.mlmodelc", embedding), ("FBank.mlmodelc", fbank)] {
        let directory = artifactURL(root, artifact)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (relativePath, data) in files {
            let file = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }
    return root
}

private final class LockedDoubles: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Double]())
    var values: [Double] { lock.withLock { $0 } }
    func append(_ value: Double) { lock.withLock { $0.append(value) } }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var value: Bool { lock.withLock { $0 } }
    func mark() { lock.withLock { $0 = true } }
}

private final class SuspendedExtractionBackend: @unchecked Sendable {
    private final class Resource {
        let release: @Sendable () -> Void
        init(release: @escaping @Sendable () -> Void) { self.release = release }
        deinit { release() }
    }
    private struct State {
        var started = false
        var released = false
        var progress: (@Sendable (Double) -> Void)?
        var continuation: CheckedContinuation<(DiarizationResult, EmbeddingModelFingerprint), Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var released: Bool { state.withLock { $0.released } }
    func process(progress: @escaping @Sendable (Double) -> Void) async throws -> (DiarizationResult, EmbeddingModelFingerprint) {
        let resource = Resource { self.state.withLock { $0.released = true } }
        defer { _fixLifetime(resource) }
        return await withCheckedContinuation { continuation in
            state.withLock {
                $0.started = true; $0.progress = progress; $0.continuation = continuation
            }
        }
    }
    func waitUntilStarted() async { while !state.withLock({ $0.started }) { await Task.yield() } }
    func report(_ value: Double) { state.withLock { $0.progress }?(value) }
    func drain() {
        let continuation = state.withLock { state -> CheckedContinuation<(DiarizationResult, EmbeddingModelFingerprint), Never>? in
            defer { state.continuation = nil; state.progress = nil }
            return state.continuation
        }
        continuation?.resume(returning: (.init(segments: []), fixtureFingerprint))
    }
}
