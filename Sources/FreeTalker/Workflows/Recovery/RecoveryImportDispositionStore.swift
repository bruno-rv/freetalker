import Foundation

enum RecoveryImportScope: Sendable, Equatable {
    case legacy
    case capture(UUID)
}

struct RecoveryImportDescriptor: Sendable, Equatable {
    let id: UUID
    let scope: RecoveryImportScope
    let contentHash: String
}

struct RecoveryImportDispositionStore: Sendable {
    private let directory: URL
    private let codec: CaptureSegmentCodec

    init(directory: URL, fileSystem: any JournalFileSystem = LocalJournalFileSystem()) {
        self.directory = directory.standardizedFileURL
        codec = CaptureSegmentCodec(fileSystem: fileSystem)
    }

    func registerImport(_ descriptor: RecoveryImportDescriptor) throws {
        try validate(descriptor)
        try commitExact(payload(descriptor), to: importURL(id: descriptor.id))
    }

    func descriptor(id: UUID) throws -> RecoveryImportDescriptor? {
        let marker = importURL(id: id)
        guard codec.fileSystem.exists(marker) else { return nil }
        let descriptor = try decode(codec.fileSystem.read(marker))
        guard descriptor.id == id else { throw CaptureJournalError.hashMismatch(marker.path) }
        return descriptor
    }

    func contains(_ descriptor: RecoveryImportDescriptor) throws -> Bool {
        try validate(descriptor)
        let marker = dispositionURL(descriptor)
        guard codec.fileSystem.exists(marker) else { return false }
        return try codec.fileSystem.read(marker) == payload(descriptor)
    }

    func record(_ descriptor: RecoveryImportDescriptor) throws {
        try validate(descriptor)
        try commitExact(payload(descriptor), to: dispositionURL(descriptor))
    }

    func descriptor(
        id: UUID, source: URL, defaultScope: RecoveryImportScope
    ) throws -> RecoveryImportDescriptor {
        if let existing = try descriptor(id: id) {
            if codec.fileSystem.exists(source) {
                guard try codec.hashFile(source) == existing.contentHash else {
                    throw CaptureJournalError.hashMismatch(source.path)
                }
            }
            return existing
        }
        guard codec.fileSystem.exists(source) else {
            throw CaptureJournalError.hashMismatch(source.path)
        }
        let descriptor = RecoveryImportDescriptor(
            id: id, scope: defaultScope, contentHash: try codec.hashFile(source)
        )
        try registerImport(descriptor)
        return descriptor
    }

    private func commitExact(_ data: Data, to destination: URL) throws {
        if codec.fileSystem.exists(destination) {
            guard try codec.fileSystem.read(destination) == data else {
                throw CaptureJournalError.hashMismatch(destination.path)
            }
            return
        }
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try DurableArtifactWriter(fileSystem: codec.fileSystem).commit(
            data, temporary: temporary, destination: destination
        )
        guard try codec.fileSystem.read(destination) == data else {
            throw CaptureJournalError.hashMismatch(destination.path)
        }
    }

    private func importURL(id: UUID) -> URL {
        directory.appendingPathComponent(".recovery-import-\(id.uuidString).marker")
    }

    private func dispositionURL(_ descriptor: RecoveryImportDescriptor) -> URL {
        switch descriptor.scope {
        case .legacy:
            directory.appendingPathComponent(
                ".recovery-disposition-legacy-\(descriptor.contentHash).marker"
            )
        case .capture(let id):
            directory.appendingPathComponent(
                ".recovery-disposition-capture-\(id.uuidString)-\(descriptor.contentHash).marker"
            )
        }
    }

    private func payload(_ descriptor: RecoveryImportDescriptor) -> Data {
        let scope = switch descriptor.scope {
        case .legacy: "legacy"
        case .capture(let id): "capture:\(id.uuidString)"
        }
        return Data("v1\n\(scope)\n\(descriptor.id.uuidString)\n\(descriptor.contentHash)".utf8)
    }

    private func decode(_ data: Data) throws -> RecoveryImportDescriptor {
        guard let value = String(data: data, encoding: .utf8) else {
            throw CaptureJournalError.failed("Invalid recovery import descriptor")
        }
        let fields = value.split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "v1",
              let id = UUID(uuidString: String(fields[2])) else {
            throw CaptureJournalError.failed("Invalid recovery import descriptor")
        }
        let scope: RecoveryImportScope
        if fields[1] == "legacy" {
            scope = .legacy
        } else if fields[1].hasPrefix("capture:"),
                  let captureID = UUID(uuidString: String(fields[1].dropFirst("capture:".count))),
                  captureID == id {
            scope = .capture(captureID)
        } else {
            throw CaptureJournalError.failed("Invalid recovery import descriptor")
        }
        let descriptor = RecoveryImportDescriptor(
            id: id, scope: scope, contentHash: String(fields[3])
        )
        guard (try? validate(descriptor)) != nil, payload(descriptor) == data else {
            throw CaptureJournalError.failed("Invalid recovery import descriptor")
        }
        return descriptor
    }

    private func validate(_ descriptor: RecoveryImportDescriptor) throws {
        guard descriptor.contentHash.count == 64,
              descriptor.contentHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw CaptureJournalError.failed("Invalid recovery import content hash")
        }
        if case .capture(let captureID) = descriptor.scope, captureID != descriptor.id {
            throw CaptureJournalError.captureMismatch
        }
    }
}
