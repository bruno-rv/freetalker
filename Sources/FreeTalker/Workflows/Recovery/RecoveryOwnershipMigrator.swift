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
                // One generic "ambiguous" for every way this guard can fail told the user that
                // ownership was contested even when the audio was simply gone or unreadable, and
                // named no file — so the Library banner it feeds (`RecoveryHealth.degraded`) was
                // neither true nor actionable. Each refusal now says which file and why; the
                // outcome for the job is unchanged.
                let name = source.lastPathComponent
                guard !dispositions.ownershipRecordExists(id: job.id) else {
                    throw CaptureJournalError.failed(
                        "\(name) is already recorded as owned by a different source"
                    )
                }
                guard references[source.path]?.count == 1 else {
                    throw CaptureJournalError.failed(
                        "\(name) is claimed by more than one recovery entry"
                    )
                }
                guard !identityOwners.contains(filenameID),
                      try dispositions.descriptor(id: filenameID) == nil,
                      !dispositions.ownershipRecordExists(id: filenameID) else {
                    throw CaptureJournalError.failed(
                        "\(name) is named after another recovery entry that still exists"
                    )
                }
                guard let before = fingerprint(source) else {
                    throw CaptureJournalError.failed(
                        "\(name) is missing, or is not a plain file inside the recovery folder"
                    )
                }
                guard RecoveryOwnedArtifactValidator(
                    root: root, id: filenameID, fileManager: .default
                ).validAudio(source) != nil else {
                    throw CaptureJournalError.failed("\(name) is not readable recovery audio")
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
                    message: "Recovery audio could not be linked to its entry: \(error.localizedDescription)"
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
