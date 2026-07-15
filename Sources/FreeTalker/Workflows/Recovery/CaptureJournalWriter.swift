import Foundation

struct CaptureDiagnostics: Sendable, Equatable, Codable {
    let peak: Float
    let rms: Float
    let inputDeviceUID: String?
    let routeFailure: String?

    var indicatesSilence: Bool {
        let deadSignalFloor: Float = 1e-7
        return peak.isFinite && rms.isFinite && peak >= 0 && rms >= 0
            && peak <= deadSignalFloor && rms <= deadSignalFloor
    }
}

struct ActiveCaptureJournal: @unchecked Sendable {
    let session: CaptureSession
    let writer: CaptureJournalWriter
}

struct StagedCapture: Sendable, Equatable {
    let captureID: UUID
    let canonicalAudioURL: URL
    let segments: [CaptureSegment]
    let sampleCount: Int
    let diagnostics: CaptureDiagnostics
}

final class CaptureJournalWriter: @unchecked Sendable {
    struct Configuration: Sendable {
        let segmentFrames: Int
        let maximumQueuedFrames: Int

        static let `default` = Configuration(
            segmentFrames: 8_000,
            maximumQueuedFrames: 128_000
        )
    }

    enum EnqueueResult: Equatable, Sendable {
        case accepted
        case overflow
        case failed(String)
    }

    private enum Status {
        case active
        case finishing
        case finished(StagedCapture)
        case failed(CaptureJournalError)
    }

    private struct State {
        var status: Status = .active
        var queue: [[Float]] = []
        var queuedFrames = 0
        var maximumObservedQueuedFrames = 0
        var pending: [Float] = []
        var committed: [CaptureSegment] = []
        var workerRunning = false
        var processing = false
        var needsBootstrap = true
        var didNotifyFailure = false
        var canonicalContentHash: String?
        var diagnostics: CaptureDiagnostics
    }

    private let session: CaptureSession
    private let fileSystem: any JournalFileSystem
    private let ledger: any CaptureLedgerStoring
    private let codec: CaptureSegmentCodec
    private let configuration: Configuration
    private let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var state: State

    init(
        session: CaptureSession,
        fileSystem: any JournalFileSystem,
        ledger: any CaptureLedgerStoring,
        codec: CaptureSegmentCodec? = nil,
        configuration: Configuration = .default,
        diagnostics: CaptureDiagnostics? = nil,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        precondition(configuration.segmentFrames > 0)
        precondition(configuration.maximumQueuedFrames > 0)
        self.session = session
        self.fileSystem = fileSystem
        self.ledger = ledger
        self.codec = codec ?? CaptureSegmentCodec(fileSystem: fileSystem)
        self.configuration = configuration
        self.onFailure = onFailure
        state = State(diagnostics: diagnostics ?? CaptureDiagnostics(
            peak: 0, rms: 0, inputDeviceUID: session.inputDeviceUID, routeFailure: nil
        ))
    }

    nonisolated func enqueue(_ samples: [Float]) -> EnqueueResult {
        guard !samples.isEmpty else { return .accepted }
        let copied = samples.withUnsafeBufferPointer { Array($0) }
        var startWorker = false
        var notify: String?
        let result: EnqueueResult = lock.withLock {
            switch state.status {
            case .failed(let error): return .failed(String(describing: error))
            case .finishing, .finished: return .failed("capture already finished")
            case .active: break
            }
            guard copied.count <= configuration.maximumQueuedFrames - state.queuedFrames else {
                let error = CaptureJournalError.queueOverflow(
                    maximumFrames: configuration.maximumQueuedFrames
                )
                state.status = .failed(error)
                state.queue.removeAll(keepingCapacity: false)
                if !state.didNotifyFailure {
                    state.didNotifyFailure = true
                    notify = String(describing: error)
                }
                return .overflow
            }
            state.queue.append(copied)
            state.queuedFrames += copied.count
            state.maximumObservedQueuedFrames = max(
                state.maximumObservedQueuedFrames, state.queuedFrames
            )
            if !state.workerRunning {
                state.workerRunning = true
                startWorker = true
            }
            return .accepted
        }
        if let notify {
            Task { onFailure(notify) }
        }
        if startWorker { launchWorker() }
        return result
    }

    func finish() async throws -> StagedCapture {
        var startWorker = false
        let immediate: Result<StagedCapture, CaptureJournalError>? = lock.withLock {
            switch state.status {
            case .finished(let staged): return .success(staged)
            case .failed(let error): return .failure(error)
            case .active:
                state.status = .finishing
                if !state.workerRunning {
                    state.workerRunning = true
                    startWorker = true
                }
                return nil
            case .finishing: return nil
            }
        }
        if let immediate { return try immediate.get() }
        if startWorker { launchWorker() }

        while true {
            let terminal: Result<StagedCapture, CaptureJournalError>? = lock.withLock {
                switch state.status {
                case .finished(let staged): .success(staged)
                case .failed(let error): .failure(error)
                case .active, .finishing: nil
                }
            }
            if let terminal { return try terminal.get() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func committedSnapshot() async -> [CaptureSegment] {
        var startWorker = false
        lock.withLock {
            if !state.workerRunning, case .active = state.status {
                state.workerRunning = true
                startWorker = true
            }
        }
        if startWorker { launchWorker() }
        while true {
            let snapshot: [CaptureSegment]? = lock.withLock {
                if case .failed = state.status { return state.committed }
                guard state.queue.isEmpty, !state.processing, !state.needsBootstrap else {
                    return nil
                }
                return state.committed
            }
            if let snapshot { return snapshot }
            await Task.yield()
        }
    }

    func queueMetrics() -> (current: Int, maximum: Int) {
        lock.withLock { (state.queuedFrames, state.maximumObservedQueuedFrames) }
    }

    func updateDiagnostics(_ diagnostics: CaptureDiagnostics) {
        lock.withLock { state.diagnostics = diagnostics }
    }

    func finishedContentHash() -> String? {
        lock.withLock { state.canonicalContentHash }
    }

    func stop() async {
        lock.withLock {
            switch state.status {
            case .active, .finishing:
                state.status = .failed(.failed("capture stopped"))
                state.queue.removeAll(keepingCapacity: false)
            case .finished, .failed:
                break
            }
        }
        while lock.withLock({ state.workerRunning || state.processing }) {
            await Task.yield()
        }
    }

    private func launchWorker() {
        Task { await runWorker() }
    }

    private func runWorker() async {
        do {
            try await bootstrap()
            while true {
                enum Action { case buffers([[Float]], [Float]), finish([Float]), stop }
                let action: Action = lock.withLock {
                    if case .failed = state.status {
                        state.workerRunning = false
                        state.processing = false
                        return .stop
                    }
                    if !state.queue.isEmpty {
                        let buffers = state.queue
                        let pending = state.pending
                        state.queue.removeAll(keepingCapacity: true)
                        state.pending = []
                        state.processing = true
                        return .buffers(buffers, pending)
                    }
                    if case .finishing = state.status {
                        let pending = state.pending
                        state.pending = []
                        state.processing = true
                        return .finish(pending)
                    }
                    state.workerRunning = false
                    state.processing = false
                    return .stop
                }

                switch action {
                case .buffers(let buffers, var pending):
                    for buffer in buffers {
                        pending.append(contentsOf: buffer)
                        while pending.count >= configuration.segmentFrames {
                            let segmentSamples = Array(pending.prefix(configuration.segmentFrames))
                            pending.removeFirst(configuration.segmentFrames)
                            try await commit(segmentSamples)
                        }
                    }
                    lock.withLock {
                        state.pending = pending
                        state.processing = false
                    }
                case .finish(let pending):
                    if !pending.isEmpty { try await commit(pending) }
                    try completeFinish()
                    return
                case .stop:
                    return
                }
            }
        } catch {
            latchFailure(error)
        }
    }

    private func bootstrap() async throws {
        guard lock.withLock({ state.needsBootstrap }) else { return }
        if let persisted = try await ledger.session(id: session.id), persisted.state == .damaged {
            throw CaptureJournalError.failed(
                persisted.failureMessage ?? "capture journal is damaged"
            )
        }
        var committed = try await ledger.committedSegments(captureID: session.id)
        committed.sort { $0.ordinal < $1.ordinal }
        for (expected, segment) in committed.enumerated() {
            guard segment.captureID == session.id else {
                throw CaptureJournalError.captureMismatch
            }
            guard segment.ordinal == expected else {
                throw CaptureJournalError.invalidOrdinal(expected: expected, actual: segment.ordinal)
            }
            _ = try codec.validate(segment)
        }

        let knownOrdinals = Set(committed.map(\.ordinal))
        let files = try fileSystem.contents(session.directory)
        for temporary in files where temporary.pathExtension == "tmp" {
            try? fileSystem.remove(temporary)
        }
        let orphanURLs = files.compactMap { url -> (Int, URL)? in
            guard url.pathExtension == "wav", let ordinal = CaptureSegmentCodec.ordinal(from: url),
                  !knownOrdinals.contains(ordinal) else { return nil }
            return (ordinal, url)
        }.sorted { $0.0 < $1.0 }
        for (ordinal, url) in orphanURLs {
            guard ordinal == committed.count else {
                throw CaptureJournalError.invalidOrdinal(expected: committed.count, actual: ordinal)
            }
            let data = try fileSystem.read(url)
            let samples = try codec.decode(url)
            let segment = CaptureSegment(
                captureID: session.id, ordinal: ordinal, url: url,
                sampleCount: samples.count, contentHash: codec.hash(data)
            )
            try await ledger.recordCommittedSegment(segment)
            committed.append(segment)
        }

        lock.withLock {
            state.committed = committed
            state.needsBootstrap = false
        }
    }

    private func commit(_ samples: [Float]) async throws {
        let ordinal = lock.withLock { state.committed.count }
        let destination = session.directory.appendingPathComponent(
            String(format: "segment-%08d.wav", ordinal)
        )
        let temporary = session.directory.appendingPathComponent(
            ".segment-\(String(format: "%08d", ordinal)).\(UUID().uuidString).tmp"
        )
        let data = codec.encode(samples)
        defer {
            if fileSystem.exists(temporary) { try? fileSystem.remove(temporary) }
        }
        do {
            try DurableArtifactWriter(fileSystem: fileSystem).commit(
                data, temporary: temporary, destination: destination
            )
            let segment = CaptureSegment(
                captureID: session.id, ordinal: ordinal, url: destination,
                sampleCount: samples.count, contentHash: codec.hash(data)
            )
            try await ledger.recordCommittedSegment(segment)
            lock.withLock {
                state.committed.append(segment)
                state.queuedFrames -= samples.count
            }
        } catch {
            if !fileSystem.exists(destination) {
                try? await ledger.transition(
                    id: session.id, from: .capturing, to: .damaged,
                    recoveryJobID: nil, libraryDictationID: nil, assetKind: .damaged,
                    failureMessage: String(describing: error), contentHash: nil
                )
            }
            throw error
        }
    }

    private func completeFinish() throws {
        let values = lock.withLock { (state.committed, state.diagnostics) }
        let canonicalURL = session.directory.appendingPathComponent("\(session.id.uuidString).wav")
        let assembled = try codec.assemble(segments: values.0, canonicalURL: canonicalURL)
        let staged = StagedCapture(
            captureID: session.id, canonicalAudioURL: canonicalURL, segments: values.0,
            sampleCount: assembled.sampleCount, diagnostics: values.1
        )
        lock.withLock {
            state.processing = false
            state.workerRunning = false
            state.canonicalContentHash = assembled.contentHash
            state.status = .finished(staged)
        }
    }

    private func latchFailure(_ error: Error) {
        let journalError = error as? CaptureJournalError ?? .failed(String(describing: error))
        var notify: String?
        lock.withLock {
            if case .failed = state.status {
                state.processing = false
                state.workerRunning = false
                return
            }
            state.status = .failed(journalError)
            state.queue.removeAll(keepingCapacity: false)
            state.processing = false
            state.workerRunning = false
            if !state.didNotifyFailure {
                state.didNotifyFailure = true
                notify = String(describing: journalError)
            }
        }
        if let notify { onFailure(notify) }
    }
}
