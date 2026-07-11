import Foundation
import os

protocol TimestampedTranscribing: Sendable {
    func transcribeFile(at url: URL, language: String?, model: String) async throws -> [TranscriptSegment]
}

struct WhisperFileRequest: Sendable, Equatable {
    let url: URL
    let language: String?
    let model: String
}

struct RawTranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

protocol WhisperFileTranscriptionBackend: Sendable {
    func transcribeFile(_ request: WhisperFileRequest) async throws -> [RawTranscriptSegment]
}

enum MediaAdapterError: Error, Equatable, LocalizedError {
    case invalidTranscriptSegment(index: Int)
    case invalidSpeakerTurn(index: Int)

    var errorDescription: String? {
        switch self {
        case .invalidTranscriptSegment(let index):
            "Transcription returned an invalid timestamp interval at segment \(index + 1)."
        case .invalidSpeakerTurn(let index):
            "Speaker separation returned an invalid speaker interval at turn \(index + 1)."
        }
    }
}

private final class PromptCancellationGate<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Error>?
        var task: Task<Void, Never>?
        var result: Result<Value, Error>?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(_ operation: @escaping @Sendable () async throws -> Value) {
        let task = Task {
            let result: Result<Value, Error>
            do { result = .success(try await operation()) }
            catch { result = .failure(error) }
            finish(result)
        }
        let cancelled = state.withLock { current in
            current.task = task
            return current.cancelled
        }
        if cancelled { task.cancel() }
    }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = state.withLock { current -> Result<Value, Error>? in
                if current.cancelled { return .failure(CancellationError()) }
                if let result = current.result { return result }
                current.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    func cancel() {
        let values = state.withLock { current -> (Task<Void, Never>?, CheckedContinuation<Value, Error>?) in
            guard !current.cancelled, current.result == nil else { return (nil, nil) }
            current.cancelled = true
            let continuation = current.continuation
            current.continuation = nil
            return (current.task, continuation)
        }
        values.0?.cancel()
        values.1?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<Value, Error>) {
        let continuation = state.withLock { current -> CheckedContinuation<Value, Error>? in
            guard !current.cancelled, current.result == nil else { return nil }
            current.result = result
            let continuation = current.continuation
            current.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

func withPromptCancellation<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    let gate = PromptCancellationGate<Value>()
    gate.start(operation)
    return try await withTaskCancellationHandler {
        try await gate.wait()
    } onCancel: {
        gate.cancel()
    }
}

struct TimestampedWhisperTranscriber<Backend: WhisperFileTranscriptionBackend>: TimestampedTranscribing {
    private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    func transcribeFile(at url: URL, language: String?, model: String) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let request = WhisperFileRequest(url: url, language: language, model: model)
        let raw = try await withPromptCancellation { try await backend.transcribeFile(request) }
        try Task.checkCancellation()
        return try raw.enumerated().map { index, segment in
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end > segment.start else {
                throw MediaAdapterError.invalidTranscriptSegment(index: index)
            }
            return TranscriptSegment(start: segment.start, end: segment.end, text: segment.text)
        }
    }
}
