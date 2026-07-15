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
        try commitExact(payload(descriptor), to: importURL(descriptor))
    }

    func descriptor(id: UUID) throws -> RecoveryImportDescriptor? {
        if let capture = try descriptor(scope: .capture(id), legacyHash: nil) {
            return capture
        }
        let oldMarker = legacyImportURL(id: id)
        var oldLegacy: RecoveryImportDescriptor?
        if codec.fileSystem.exists(oldMarker) {
            let decoded = try decode(codec.fileSystem.read(oldMarker))
            guard decoded.id == id else {
                throw CaptureJournalError.hashMismatch(oldMarker.path)
            }
            if decoded.scope == .legacy { oldLegacy = decoded }
        }
        for marker in try codec.fileSystem.contents(directory)
        where marker.lastPathComponent.hasPrefix(".recovery-import-legacy-") {
            let decoded = try decode(codec.fileSystem.read(marker))
            if decoded.id == id, decoded.scope == .legacy { return decoded }
        }
        return oldLegacy
    }

    func descriptor(
        scope: RecoveryImportScope, legacyHash: String?
    ) throws -> RecoveryImportDescriptor? {
        let marker: URL
        let legacyID: UUID
        switch scope {
        case .capture(let id):
            marker = captureImportURL(id: id)
            legacyID = id
        case .legacy:
            guard let legacyHash else {
                throw CaptureJournalError.failed("Legacy recovery hash is unavailable")
            }
            marker = legacyImportURL(hash: legacyHash)
            legacyID = LegacyRecoveryImporter.stableID(hash: legacyHash)
        }
        if codec.fileSystem.exists(marker) {
            let decoded = try decode(codec.fileSystem.read(marker))
            guard decoded.scope == scope else {
                throw CaptureJournalError.hashMismatch(marker.path)
            }
            return decoded
        }
        let oldMarker = legacyImportURL(id: legacyID)
        guard codec.fileSystem.exists(oldMarker) else { return nil }
        let decoded = try decode(codec.fileSystem.read(oldMarker))
        return decoded.scope == scope ? decoded : nil
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

    func registerOwnedSource(id: UUID, source: URL) throws {
        let descriptor = try descriptor(
            id: id, source: source, defaultScope: .capture(id)
        )
        try registerOwnedSource(id: id, source: source, expectedHash: descriptor.contentHash)
    }

    func registerOwnedSource(id: UUID, source: URL, expectedHash: String) throws {
        let descriptor = RecoveryImportDescriptor(
            id: id, scope: .capture(id), contentHash: expectedHash
        )
        try validate(descriptor)
        guard codec.fileSystem.exists(source), try codec.hashFile(source) == expectedHash else {
            throw CaptureJournalError.hashMismatch(source.path)
        }
        if let existing = try self.descriptor(id: id) {
            guard existing == descriptor else {
                throw CaptureJournalError.hashMismatch(source.path)
            }
        } else {
            try registerImport(descriptor)
        }
        guard try codec.hashFile(source) == expectedHash else {
            throw CaptureJournalError.hashMismatch(source.path)
        }
        try commitExact(
            ownershipPayload(
                id: id, path: source.standardizedFileURL.path,
                hash: expectedHash
            ),
            to: ownershipURL(id: id)
        )
        guard try codec.hashFile(source) == expectedHash else {
            throw CaptureJournalError.hashMismatch(source.path)
        }
    }

    func ownershipRecordExists(id: UUID) -> Bool {
        codec.fileSystem.exists(ownershipURL(id: id))
    }

    func ownsSource(id: UUID, source: URL, requireCurrentHash: Bool = true) throws -> Bool {
        let marker = ownershipURL(id: id)
        guard codec.fileSystem.exists(marker) else { return false }
        let fields = String(decoding: try codec.fileSystem.read(marker), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "v1", fields[1] == id.uuidString,
              fields[2] == source.standardizedFileURL.path else { return false }
        let hash = String(fields[3])
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return false
        }
        if requireCurrentHash, try codec.hashFile(source) != hash { return false }
        guard let descriptor = try descriptor(id: id) else { return false }
        return descriptor.id == id && descriptor.contentHash == hash
    }

    func descriptor(
        id: UUID, source: URL, defaultScope: RecoveryImportScope
    ) throws -> RecoveryImportDescriptor {
        if let capture = try descriptor(scope: .capture(id), legacyHash: nil) {
            if codec.fileSystem.exists(source),
               try codec.hashFile(source) != capture.contentHash {
                throw CaptureJournalError.hashMismatch(source.path)
            }
            return capture
        }
        if codec.fileSystem.exists(source) {
            let hash = try codec.hashFile(source)
            if let legacy = try descriptor(scope: .legacy, legacyHash: hash),
               legacy.id == id {
                return legacy
            }
            let descriptor = RecoveryImportDescriptor(
                id: id, scope: defaultScope, contentHash: hash
            )
            try registerImport(descriptor)
            return descriptor
        }
        guard let existing = try descriptor(id: id) else {
            throw CaptureJournalError.hashMismatch(source.path)
        }
        return existing
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

    private func importURL(_ descriptor: RecoveryImportDescriptor) -> URL {
        switch descriptor.scope {
        case .capture(let id): captureImportURL(id: id)
        case .legacy: legacyImportURL(hash: descriptor.contentHash)
        }
    }

    private func captureImportURL(id: UUID) -> URL {
        directory.appendingPathComponent(".recovery-import-capture-\(id.uuidString).marker")
    }

    private func legacyImportURL(hash: String) -> URL {
        directory.appendingPathComponent(".recovery-import-legacy-\(hash).marker")
    }

    private func legacyImportURL(id: UUID) -> URL {
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

    private func ownershipURL(id: UUID) -> URL {
        directory.appendingPathComponent(".recovery-ownership-\(id.uuidString).marker")
    }

    private func ownershipPayload(id: UUID, path: String, hash: String) -> Data {
        Data("v1\n\(id.uuidString)\n\(path)\n\(hash)".utf8)
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
