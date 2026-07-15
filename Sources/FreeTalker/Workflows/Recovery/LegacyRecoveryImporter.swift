import Foundation

struct RecoveryRegistrationRetrier: Sendable {
    static let delays: [Duration] = [.zero, .milliseconds(250), .seconds(1)]
    let sleep: @Sendable (Duration) async -> Void

    init(sleep: @escaping @Sendable (Duration) async -> Void = { delay in
        guard delay > .zero else { return }
        do { try await Task.sleep(for: delay) } catch { return }
    }) {
        self.sleep = sleep
    }

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        var finalError: Error?
        for delay in Self.delays {
            await sleep(delay)
            do {
                try await operation()
                return
            } catch {
                finalError = error
            }
        }
        throw finalError ?? CancellationError()
    }
}

struct LegacyRecoveryImporter: Sendable {
    enum Result: Sendable, Equatable { case imported, duplicate, quarantined }

    let store: TranscriptionJobStore
    let codec: CaptureSegmentCodec
    let retrier: RecoveryRegistrationRetrier

    func importAudio(_ source: URL, preferredID: UUID? = nil) async throws -> Result {
        let data = try codec.fileSystem.read(source)
        let hash = codec.hash(data)
        let id = preferredID ?? Self.stableID(hash: hash)
        if try await store.job(id: id) != nil { return .duplicate }

        let valid: Bool
        do {
            _ = try RecoveryRetryPipeline.loadPCM(from: source)
            valid = true
        } catch {
            valid = false
        }
        let message = valid
            ? "Recovered audio is ready to process"
            : "Damaged or unsupported recovery audio was quarantined"
        try await retrier.run {
            let job = if let existing = try await store.job(id: id) {
                existing
            } else {
                try await store.createProvisionalRecovery(
                    id: id, source: JobSource(reference: source.path), capturedAt: Self.creationDate(source)
                )
            }
            if case .processing = job.state {
                try await store.failProvisionalRecovery(
                    id: id, failure: JobFailure(stage: .preparing, message: message)
                )
            }
        }
        return valid ? .imported : .quarantined
    }

    private static func creationDate(_ url: URL) -> Date {
        do { return try url.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date() }
        catch { return Date() }
    }

    static func stableID(hash: String) -> UUID {
        let hex = String(hash.prefix(32)).padding(toLength: 32, withPad: "0", startingAt: 0)
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-"
            + "\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: value)!
    }
}
