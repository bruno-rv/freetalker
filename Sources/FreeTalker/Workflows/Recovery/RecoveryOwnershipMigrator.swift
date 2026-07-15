import Foundation

struct RecoveryOwnershipMigrationIssue: Sendable, Equatable {
    let source: URL
    let message: String
}

struct RecoveryOwnershipMigrationResult: Sendable, Equatable {
    var protectedPaths: Set<String> = []
    var issues: [RecoveryOwnershipMigrationIssue] = []
}

struct RecoveryOwnershipMigrator: Sendable {
    let root: URL
    let fileSystem: any JournalFileSystem

    init(root: URL, fileSystem: any JournalFileSystem = LocalJournalFileSystem()) {
        self.root = root.standardizedFileURL
        self.fileSystem = fileSystem
    }

    func migrate(
        jobs: [TranscriptionJob], sessions: [CaptureSession]
    ) -> RecoveryOwnershipMigrationResult {
        var result = RecoveryOwnershipMigrationResult()
        let dispositions = RecoveryImportDispositionStore(directory: root, fileSystem: fileSystem)
        let identityOwners = Set(jobs.map(\.id))
            .union(sessions.flatMap { [$0.id, $0.recoveryJobID].compactMap { $0 } })
        let references = Dictionary(grouping: jobs) {
            URL(fileURLWithPath: $0.source.reference).standardizedFileURL.path
        }

        for job in jobs where job.kind == .recovery {
            let source = URL(fileURLWithPath: job.source.reference).standardizedFileURL
            guard source.deletingLastPathComponent() == root,
                  source.pathExtension.lowercased() == "wav",
                  let filenameID = UUID(
                    uuidString: source.deletingPathExtension().lastPathComponent
                  ), filenameID != job.id else { continue }
            // Once an existing job claims this exact legacy path, reconciliation must
            // never reinterpret ambiguous bytes as a filename-owned orphan.
            result.protectedPaths.insert(source.path)
            do {
                if try dispositions.ownsSource(id: job.id, source: source) {
                    continue
                }
                guard !dispositions.ownershipRecordExists(id: job.id),
                      references[source.path]?.count == 1,
                      !identityOwners.contains(filenameID),
                      try dispositions.descriptor(id: filenameID) == nil,
                      !dispositions.ownershipRecordExists(id: filenameID),
                      let before = fingerprint(source),
                      RecoveryOwnedArtifactValidator(
                        root: root, id: filenameID, fileManager: .default
                      ).validAudio(source) != nil else {
                    throw CaptureJournalError.failed(
                        "Markerless recovery ownership is ambiguous"
                    )
                }
                let hash = try CaptureSegmentCodec(fileSystem: fileSystem).hashFile(source)
                guard fingerprint(source) == before else {
                    throw CaptureJournalError.hashMismatch(source.path)
                }
                if let descriptor = try dispositions.descriptor(id: job.id) {
                    guard descriptor == RecoveryImportDescriptor(
                        id: job.id, scope: .capture(job.id), contentHash: hash
                    ), try !dispositions.contains(descriptor) else {
                        throw CaptureJournalError.hashMismatch(source.path)
                    }
                }
                try dispositions.registerOwnedSource(
                    id: job.id, source: source, expectedHash: hash
                )
                guard fingerprint(source) == before,
                      try dispositions.ownsSource(id: job.id, source: source) else {
                    throw CaptureJournalError.hashMismatch(source.path)
                }
            } catch {
                result.issues.append(.init(
                    source: source,
                    message: "Recovery ownership could not be safely upgraded: \(error.localizedDescription)"
                ))
            }
        }
        return result
    }

    private func fingerprint(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
        url.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath()
        else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? -1
        return "\(values.fileSize ?? -1):\(modified)"
    }
}
