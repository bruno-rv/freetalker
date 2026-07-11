import Foundation
import UniformTypeIdentifiers

enum MediaImportError: LocalizedError, Equatable {
    case unsupportedType
    case missingBookmark
    case staleBookmark
    case securityScopeDenied
    case jobNotFound
    case noAudioTrack
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Choose a WAV, M4A, MP3, MP4, or MOV file."
        case .missingBookmark: "The imported file no longer has a saved access bookmark."
        case .staleBookmark: "The imported file's saved access is stale. Choose the file again."
        case .securityScopeDenied: "FreeTalker could not access the imported file."
        case .jobNotFound: "The media import job no longer exists."
        case .noAudioTrack: "The selected video does not contain an audio track."
        case .decodeFailed(let message): "The media audio could not be decoded: \(message)"
        }
    }
}

struct ResolvedSecurityScopedURL: Sendable {
    let url: URL
    let isStale: Bool
}

protocol SecurityScopedBookmarkAccessing: Sendable {
    func createBookmark(for url: URL) async throws -> Data
    func resolveBookmark(_ data: Data) async throws -> ResolvedSecurityScopedURL
    func startAccessing(_ url: URL) async -> Bool
    func stopAccessing(_ url: URL) async
}

struct FoundationSecurityScopedBookmarkAccess: SecurityScopedBookmarkAccessing {
    func createBookmark(for url: URL) async throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data) async throws -> ResolvedSecurityScopedURL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return ResolvedSecurityScopedURL(url: url, isStale: stale)
    }

    func startAccessing(_ url: URL) async -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) async { url.stopAccessingSecurityScopedResource() }
}

protocol MediaImportJobStoring: Sendable {
    func create(kind: JobKind, source: JobSource, now: Date) async throws -> TranscriptionJob
    func job(id: UUID) async throws -> TranscriptionJob?
}

extension TranscriptionJobStore: MediaImportJobStoring {}

protocol MediaAudioDecoding: Sendable {
    func decode(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void,
        cancellation: CancellationToken
    ) async throws
}

struct MediaImportService: Sendable {
    private static let supportedExtensions: Set<String> = ["wav", "m4a", "mp3", "mp4", "mov"]

    private let store: any MediaImportJobStoring
    private let bookmarkAccess: any SecurityScopedBookmarkAccessing
    private let decoder: any MediaAudioDecoding
    private let clock: @Sendable () -> Date

    init(
        store: any MediaImportJobStoring,
        bookmarkAccess: any SecurityScopedBookmarkAccessing = FoundationSecurityScopedBookmarkAccess(),
        decoder: any MediaAudioDecoding = AVAudioDecoder(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.bookmarkAccess = bookmarkAccess
        self.decoder = decoder
        self.clock = clock
    }

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext), let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    func createJob(for sourceURL: URL) async throws -> UUID {
        guard Self.isSupported(sourceURL) else { throw MediaImportError.unsupportedType }
        let bookmark = try await bookmarkAccess.createBookmark(for: sourceURL)
        let source = JobSource(reference: sourceURL.path, bookmark: bookmark)
        return try await store.create(kind: .mediaImport, source: source, now: clock()).id
    }

    func decode(
        jobID: UUID,
        destination: URL,
        cancellation: CancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let job = try await store.job(id: jobID) else { throw MediaImportError.jobNotFound }
        guard let bookmark = job.source.bookmark else { throw MediaImportError.missingBookmark }
        let resolved = try await bookmarkAccess.resolveBookmark(bookmark)
        guard !resolved.isStale else { throw MediaImportError.staleBookmark }
        guard await bookmarkAccess.startAccessing(resolved.url) else { throw MediaImportError.securityScopeDenied }
        do {
            try await decoder.decode(source: resolved.url, destination: destination, progress: progress, cancellation: cancellation)
            await bookmarkAccess.stopAccessing(resolved.url)
        } catch {
            await bookmarkAccess.stopAccessing(resolved.url)
            throw error
        }
    }
}
