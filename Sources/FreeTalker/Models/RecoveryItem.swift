import AVFoundation
import Foundation

enum RecoveryAction: Hashable, Sendable {
    case retryProcessing
    case exportAudio
    case exportArtifact
    case startNewRecording
    case delete
}

struct RecoveryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let job: TranscriptionJob?
    let session: CaptureSession?
    let audioURL: URL?
    let artifactURL: URL?
    let availableActions: Set<RecoveryAction>
    let message: String

    init?(
        session: CaptureSession?,
        job: TranscriptionJob?,
        recoveryRoot: URL,
        fileManager: FileManager = .default
    ) {
        guard let id = session?.id ?? job?.id,
              session == nil || job == nil || session?.id == job?.id else { return nil }
        guard session?.state != .libraryCommitted else { return nil }
        if let job, job.state == .ready || job.state == .cancelled { return nil }

        let validator = RecoveryOwnedArtifactValidator(
            root: recoveryRoot, id: id, fileManager: fileManager
        )
        let source = job.map { URL(fileURLWithPath: $0.source.reference) }
        let assetKind = session?.assetKind ?? .audio
        let validAudio = assetKind == .audio
            ? source.flatMap { validator.validAudio($0) }
                ?? validator.validAudio(validator.canonical(in: session?.directory))
            : nil
        let missingOwnedAudio = source.flatMap { validator.ownedMissingAudio($0) }
        let retainedArtifact: URL? = switch assetKind {
        case .damaged, .quarantined:
            source.flatMap { validator.validArtifact($0) }
                ?? validator.firstArtifact(in: session?.directory)
        case .audio, .silent:
            nil
        }

        var actions: Set<RecoveryAction> = []
        switch assetKind {
        case .silent:
            actions = [.startNewRecording, .delete]
        case .damaged, .quarantined:
            actions = retainedArtifact == nil ? [.delete] : [.exportArtifact, .delete]
        case .audio:
            if validAudio != nil {
                actions.insert(.exportAudio)
                if case .failed = job?.state { actions.insert(.retryProcessing) }
                if case .failed = job?.state { actions.insert(.delete) }
                if job == nil, session?.state == .staged { actions.insert(.delete) }
            } else if missingOwnedAudio != nil, case .failed = job?.state {
                actions.insert(.delete)
            }
        }

        self.id = id
        self.job = job
        self.session = session
        audioURL = validAudio
        artifactURL = retainedArtifact
        availableActions = actions
        message = if assetKind == .audio, source != nil, validAudio == nil,
                     missingOwnedAudio == nil {
            "Saved audio ownership could not be verified. FreeTalker will not retry, export, or delete it."
        } else { session?.failureMessage
            ?? job?.failureMessage
            ?? (assetKind == .silent ? SilentCapturePresentation.message : Self.defaultMessage(assetKind)) }
    }

    private static func defaultMessage(_ kind: RecoveryAssetKind) -> String {
        switch kind {
        case .audio: "Saved audio is available for recovery."
        case .silent: SilentCapturePresentation.message
        case .damaged: "The captured audio is damaged."
        case .quarantined: "The captured artifact was quarantined."
        }
    }
}

struct RecoveryOwnedArtifactValidator {
    let root: URL
    let resolvedRoot: URL
    let id: UUID
    let fileManager: FileManager

    init(root: URL, id: UUID, fileManager: FileManager) {
        self.root = root.standardizedFileURL
        resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.id = id
        self.fileManager = fileManager
    }

    func canonical(in directory: URL?) -> URL {
        (directory ?? root).appendingPathComponent("\(id.uuidString).wav")
    }

    func validAudio(_ url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "wav",
              hasOwnedAudioIdentity(url.standardizedFileURL),
              let artifact = validArtifact(url),
              let audio = try? AVAudioFile(forReading: artifact),
              audio.length > 0 else { return nil }
        return artifact
    }

    func ownedMissingAudio(_ url: URL) -> URL? {
        let lexical = url.standardizedFileURL
        guard !fileManager.fileExists(atPath: lexical.path),
              hasOwnedAudioIdentity(lexical) else { return nil }
        return ownedMissingArtifact(lexical)
    }

    func validArtifact(_ url: URL) -> URL? {
        let lexical = url.standardizedFileURL
        guard hasOwnedIdentity(lexical), isRegularNonSymlink(lexical) else { return nil }
        let resolved = lexical.resolvingSymlinksInPath()
        guard isOwnedResolved(resolved) else { return nil }
        return lexical
    }

    func ownedMissingArtifact(_ url: URL) -> URL? {
        let lexical = url.standardizedFileURL
        guard !fileManager.fileExists(atPath: lexical.path) else { return validArtifact(lexical) }
        let parent = lexical.deletingLastPathComponent()
        let nested = parent == root.appendingPathComponent(id.uuidString, isDirectory: true)
        let direct = parent == root
        guard nested || direct else { return nil }
        if nested || UUID(uuidString: lexical.deletingPathExtension().lastPathComponent) == id {
            return lexical
        }
        return (try? RecoveryImportDispositionStore(directory: root).ownsSource(
            id: id, source: lexical, requireCurrentHash: false
        )) == true ? lexical : nil
    }

    func firstArtifact(in directory: URL?) -> URL? {
        guard let directory,
              directory.standardizedFileURL == root.appendingPathComponent(id.uuidString, isDirectory: true),
              let contents = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ) else { return nil }
        let preferred = contents.sorted { lhs, rhs in
            let rank: (URL) -> Int = {
                if $0.lastPathComponent == "\(id.uuidString).wav" { return 0 }
                if $0.lastPathComponent == "capture-failure.marker" { return 1 }
                if $0.lastPathComponent.hasPrefix("segment-") { return 2 }
                return 3
            }
            return rank(lhs) == rank(rhs) ? lhs.path < rhs.path : rank(lhs) < rank(rhs)
        }
        return preferred.lazy.compactMap(validArtifact).first
    }

    private func hasOwnedIdentity(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        if parent == root.appendingPathComponent(id.uuidString, isDirectory: true) {
            return true
        }
        guard parent == root else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        if let directID = UUID(uuidString: stem), directID == id { return true }
        return (try? RecoveryImportDispositionStore(directory: root)
            .ownsSource(id: id, source: url)) == true
    }

    private func hasOwnedAudioIdentity(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        if parent == root.appendingPathComponent(id.uuidString, isDirectory: true) {
            return url.lastPathComponent == "\(id.uuidString).wav"
        }
        guard parent == root else { return false }
        if UUID(uuidString: url.deletingPathExtension().lastPathComponent) == id { return true }
        return (try? RecoveryImportDispositionStore(directory: root)
            .ownsSource(id: id, source: url)) == true
    }

    private func isOwnedResolved(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        return parent == resolvedRoot
            || parent == resolvedRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func isRegularNonSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

private extension TranscriptionJob {
    var failureMessage: String? {
        guard case .failed(let failure) = state else { return nil }
        return failure.message
    }
}
