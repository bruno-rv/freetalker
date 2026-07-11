@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum MediaImportError: LocalizedError, Equatable {
    case unsupportedType
    case invalidMedia
    case missingBookmark
    case staleBookmark
    case securityScopeDenied
    case jobNotFound
    case noAudioTrack
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Choose a WAV, M4A, MP3, MP4, or MOV file."
        case .invalidMedia: "The selected file is not readable local audio or video media."
        case .missingBookmark: "The imported file no longer has a saved access bookmark."
        case .staleBookmark: "The imported file's saved access is stale. Choose the file again."
        case .securityScopeDenied: "FreeTalker could not access the imported file."
        case .jobNotFound: "The media import job no longer exists."
        case .noAudioTrack: "The selected video does not contain an audio track."
        case .decodeFailed(let message): "The media audio could not be decoded: \(message)"
        }
    }
}

protocol MediaAssetProbing: Sendable {
    func validateAudio(at url: URL) async throws
}

struct AVMediaAssetProbe: MediaAssetProbing {
    func validateAudio(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        do {
            async let readable = asset.load(.isReadable)
            async let playable = asset.load(.isPlayable)
            guard try await readable, try await playable else { throw MediaImportError.invalidMedia }
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw MediaImportError.noAudioTrack
            }
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.invalidMedia
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
    private let mediaProbe: any MediaAssetProbing
    private let decoder: any MediaAudioDecoding
    private let clock: @Sendable () -> Date

    init(
        store: any MediaImportJobStoring,
        bookmarkAccess: any SecurityScopedBookmarkAccessing = FoundationSecurityScopedBookmarkAccess(),
        decoder: any MediaAudioDecoding = AVAudioDecoder(),
        mediaProbe: any MediaAssetProbing = AVMediaAssetProbe(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.bookmarkAccess = bookmarkAccess
        self.decoder = decoder
        self.mediaProbe = mediaProbe
        self.clock = clock
    }

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext), let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    func createJob(for sourceURL: URL) async throws -> UUID {
        guard Self.isSupported(sourceURL) else { throw MediaImportError.unsupportedType }
        guard await bookmarkAccess.startAccessing(sourceURL) else { throw MediaImportError.securityScopeDenied }
        let bookmark: Data
        do {
            try await mediaProbe.validateAudio(at: sourceURL)
            bookmark = try await bookmarkAccess.createBookmark(for: sourceURL)
            await bookmarkAccess.stopAccessing(sourceURL)
        } catch {
            await bookmarkAccess.stopAccessing(sourceURL)
            throw error
        }
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
