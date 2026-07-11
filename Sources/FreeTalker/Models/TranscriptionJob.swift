import Foundation

enum JobKind: String, CaseIterable, Sendable, Equatable {
    case recovery = "recovery"
    case mediaImport = "media_import"
}

enum JobStage: String, CaseIterable, Sendable, Equatable {
    case preparing = "preparing"
    case transcribing = "transcribing"
    case postProcessing = "post_processing"
    case persisting = "persisting"
}

struct JobFailure: Sendable, Equatable {
    let stage: JobStage
    let message: String
}

enum JobState: Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable, Equatable {
        case queued = "queued"
        case processing = "processing"
        case ready = "ready"
        case failed = "failed"
        case cancelled = "cancelled"
    }

    case queued
    case processing(stage: JobStage)
    case ready
    case failed(JobFailure)
    case cancelled

    var kind: Kind {
        switch self {
        case .queued: .queued
        case .processing: .processing
        case .ready: .ready
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

struct JobSource: Sendable, Equatable {
    let reference: String
    let bookmark: Data?

    init(reference: String, bookmark: Data? = nil) {
        self.reference = reference
        self.bookmark = bookmark
    }
}

struct TranscriptionJob: Sendable, Equatable {
    let id: UUID
    let kind: JobKind
    let source: JobSource
    let state: JobState
    let progress: Double
    let createdAt: Date
    let updatedAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let expiresAt: Date?
    let result: String?
    let needsSourceCleanup: Bool
    let sourceCleanupError: String?
}

struct AttemptConfiguration: Sendable, Equatable {
    let language: String?
    let speechModel: String?
    let template: String?

    init(language: String? = nil, speechModel: String? = nil, template: String? = nil) {
        self.language = language
        self.speechModel = speechModel
        self.template = template
    }
}

enum AttemptResult: Sendable, Equatable {
    case succeeded
    case failed(JobFailure)
}

struct JobAttempt: Sendable, Equatable {
    let id: Int64
    let jobID: UUID
    let number: Int
    let configuration: AttemptConfiguration
    let startedAt: Date
    let completedAt: Date?
    let result: AttemptResult?
}

protocol JobClock: Sendable {
    var now: Date { get }
}

struct SystemJobClock: JobClock {
    var now: Date { Date() }
}

enum JobStoreError: Error, Equatable {
    case invalidTransition
    case purgeClaimed
    case jobNotFound
    case attemptNotFound
    case corruptData(String)
}
