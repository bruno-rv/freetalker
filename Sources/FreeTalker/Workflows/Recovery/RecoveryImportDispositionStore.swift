import Foundation

struct RecoveryImportDispositionStore: Sendable {
    private let directory: URL
    private let codec: CaptureSegmentCodec

    init(directory: URL, fileSystem: any JournalFileSystem = LocalJournalFileSystem()) {
        self.directory = directory.standardizedFileURL
        codec = CaptureSegmentCodec(fileSystem: fileSystem)
    }

    func contains(source: URL) throws -> Bool {
        try contains(hash: codec.hashFile(source))
    }

    func contains(hash: String) throws -> Bool {
        let marker = markerURL(hash: hash)
        guard codec.fileSystem.exists(marker) else { return false }
        return try codec.fileSystem.read(marker) == Data(hash.utf8)
    }

    func record(source: URL) throws {
        let hash = try codec.hashFile(source)
        let marker = markerURL(hash: hash)
        if codec.fileSystem.exists(marker) {
            guard try contains(hash: hash) else {
                throw CaptureJournalError.hashMismatch(marker.path)
            }
            return
        }
        let temporary = directory.appendingPathComponent(
            ".recovery-disposition-\(hash).\(UUID().uuidString).tmp"
        )
        try DurableArtifactWriter(fileSystem: codec.fileSystem).commit(
            Data(hash.utf8), temporary: temporary, destination: marker
        )
    }

    private func markerURL(hash: String) -> URL {
        directory.appendingPathComponent(".recovery-disposition-\(hash).marker")
    }
}
