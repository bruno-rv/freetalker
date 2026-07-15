import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryPresentationTests {
    @Test @MainActor func retentionSettingChangePurgesImmediately() async {
        let probe = RecoveryRetentionChangeProbe()
        await AppCoordinator.routeRecoveryRetentionChange(.thirtyDays) { await probe.record($0) }
        #expect(await probe.values == [.thirtyDays])
    }
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func badgeCountsOnlyRecoveriesNeedingAttention() {
        let jobs = [
            job(state: .failed(.init(stage: .transcribing, message: "Offline"))),
            job(state: .queued),
            job(state: .ready)
        ]

        #expect(RecoveryPresentation.badgeCount(jobs) == 1)
        #expect(RecoveryPresentation.badgeCount(jobs, silentCount: 2) == 3)
        #expect(RecoveryPresentation.badgeText(count: 0) == nil)
        #expect(RecoveryPresentation.badgeText(count: 3) == "3")
    }

    @Test func expiryTextUsesRetentionAndNeverMakesPromise() {
        let created = now.addingTimeInterval(-2 * 86_400)

        #expect(RecoveryPresentation.expiryText(createdAt: created, retention: .sevenDays, now: now) == "Expires in 5 days")
        #expect(RecoveryPresentation.expiryText(createdAt: created, retention: .oneDay, now: now) == "Expired — cleanup pending")
        #expect(RecoveryPresentation.expiryText(createdAt: created, retention: .never, now: now) == "Kept until deleted")
    }

    @Test func rowActionsFollowPersistedState() {
        #expect(RecoveryPresentation.actions(for: .failed(.init(stage: .transcribing, message: "x"))) == [.play, .retry, .delete])
        #expect(RecoveryPresentation.actions(for: .queued) == [.play])
        #expect(RecoveryPresentation.actions(for: .processing(stage: .transcribing)) == [.play])
        #expect(RecoveryPresentation.actions(for: .ready) == [])
    }

    @Test func projectedActionsUseCaptureAssetAndPersistedJobState() throws {
        let temp = try RecoveryPresentationTemporaryDirectory()
        let id = UUID()
        let captureDirectory = temp.url.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: false)
        let audio = captureDirectory.appendingPathComponent("\(id.uuidString).wav")
        try WAVEncoder.encode(samples: [0.25], sampleRate: 16_000).write(to: audio)
        let failed = job(id: id, source: audio, state: .failed(.init(stage: .transcribing, message: "Offline")))

        let item = try #require(RecoveryItem(
            session: session(id: id, directory: captureDirectory, state: .processing, assetKind: .audio, recoveryJobID: id),
            job: failed,
            recoveryRoot: temp.url
        ))

        #expect(item.audioURL == audio)
        #expect(item.availableActions == [.retryProcessing, .exportAudio, .delete])

        let processing = RecoveryItem(
            session: item.session,
            job: job(id: id, source: audio, state: .processing(stage: .transcribing)),
            recoveryRoot: temp.url
        )
        #expect(processing?.availableActions == [.exportAudio])
    }

    @Test func silentDamagedAndLegacyItemsNeverInventAudioActions() throws {
        let temp = try RecoveryPresentationTemporaryDirectory()
        let silent = RecoveryItem(
            session: session(id: UUID(), directory: temp.url, state: .silent, assetKind: .silent),
            job: nil,
            recoveryRoot: temp.url
        )
        #expect(silent?.message == SilentCapturePresentation.message)
        #expect(silent?.availableActions == [.startNewRecording, .delete])

        let damagedID = UUID()
        let damagedDirectory = temp.url.appendingPathComponent(damagedID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: false)
        let artifact = damagedDirectory.appendingPathComponent("capture-failure.marker")
        try Data("disk full".utf8).write(to: artifact)
        let damaged = RecoveryItem(
            session: session(id: damagedID, directory: damagedDirectory, state: .damaged, assetKind: .quarantined),
            job: nil,
            recoveryRoot: temp.url
        )
        #expect(damaged?.artifactURL == artifact)
        #expect(damaged?.availableActions == [.exportArtifact, .delete])

        let legacyID = UUID()
        let missing = temp.url.appendingPathComponent("\(legacyID.uuidString).wav")
        let legacy = RecoveryItem(
            session: nil,
            job: job(id: legacyID, source: missing, state: .failed(.init(stage: .decoding, message: "Missing"))),
            recoveryRoot: temp.url
        )
        #expect(legacy?.availableActions == [.delete])
        #expect(legacy?.audioURL == nil)
    }

    @Test func projectionRejectsOutsideSymlinkAndCorruptAudio() throws {
        let temp = try RecoveryPresentationTemporaryDirectory()
        let outside = temp.url.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: outside) }
        try WAVEncoder.encode(samples: [0.1], sampleRate: 16_000).write(to: outside)
        let id = UUID()
        let symlink = temp.url.appendingPathComponent("\(id.uuidString).wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let linked = RecoveryItem(
            session: nil,
            job: job(id: id, source: symlink, state: .failed(.init(stage: .transcribing, message: "x"))),
            recoveryRoot: temp.url
        )
        #expect(linked?.audioURL == nil)
        #expect(linked?.availableActions == [.delete])

        try FileManager.default.removeItem(at: symlink)
        try Data("not a wave".utf8).write(to: symlink)
        let corrupt = RecoveryItem(
            session: nil,
            job: job(id: id, source: symlink, state: .failed(.init(stage: .transcribing, message: "x"))),
            recoveryRoot: temp.url
        )
        #expect(corrupt?.audioURL == nil)
        #expect(corrupt?.availableActions == [.delete])
    }

    @Test func retryPresentationDistinguishesIdleQueuedAndProcessing() {
        #expect(RecoveryPresentation.retryState(for: .failed(.init(stage: .transcribing, message: "x"))) == .available)
        #expect(RecoveryPresentation.retryState(for: .queued) == .queued)
        #expect(RecoveryPresentation.retryState(for: .processing(stage: .postProcessing)) == .processing("Post-processing"))
    }

    @Test func rowStateLabelsAndIconsCoverEveryState() {
        #expect(RecoveryPresentation.stateLabel(.failed(.init(stage: .transcribing, message: "x"))) == "Needs attention")
        #expect(RecoveryPresentation.stateIcon(.failed(.init(stage: .transcribing, message: "x"))) == "exclamationmark.triangle")
        #expect(RecoveryPresentation.stateLabel(.processing(stage: .postProcessing)) == "Post-processing")
        #expect(RecoveryPresentation.stateIcon(.ready) == "checkmark.circle")
    }

    @Test func deleteConfirmationNamesIrreversibleLocalAudioRemoval() {
        #expect(RecoveryPresentation.deleteConfirmation == "Permanently delete this recovery and its saved audio? This cannot be undone.")
    }

    @Test(arguments: [
        (RecoveryRetention.oneDay, "1 day"),
        (.sevenDays, "7 days"),
        (.thirtyDays, "30 days"),
        (.ninetyDays, "90 days"),
        (.never, "Never")
    ])
    func retentionLabels(value: RecoveryRetention, label: String) {
        #expect(RecoveryPresentation.retentionLabel(value) == label)
    }

    private func job(state: JobState) -> TranscriptionJob {
        job(id: UUID(), source: URL(fileURLWithPath: "/tmp/recovery.wav"), state: state)
    }

    private func job(id: UUID, source: URL, state: JobState) -> TranscriptionJob {
        TranscriptionJob(
            id: id, kind: .recovery, source: .init(reference: source.path),
            state: state, progress: 0, createdAt: now, updatedAt: now,
            startedAt: nil, completedAt: nil, expiresAt: nil, result: nil,
            needsSourceCleanup: false, sourceCleanupError: nil
        )
    }

    private func session(
        id: UUID,
        directory: URL,
        state: CaptureSessionState,
        assetKind: RecoveryAssetKind,
        recoveryJobID: UUID? = nil
    ) -> CaptureSession {
        CaptureSession(
            id: id, state: state, directory: directory, capturedAt: now,
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil,
            destination: "external", recoveryJobID: recoveryJobID,
            libraryDictationID: nil, assetKind: assetKind,
            failureMessage: assetKind == .silent ? SilentCapturePresentation.message : "Damaged capture",
            contentHash: nil
        )
    }
}

private final class RecoveryPresentationTemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private actor RecoveryRetentionChangeProbe {
    private(set) var values: [RecoveryRetention] = []
    func record(_ value: RecoveryRetention) { values.append(value) }
}
