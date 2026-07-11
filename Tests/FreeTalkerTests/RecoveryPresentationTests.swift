import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func badgeCountsOnlyRecoveriesNeedingAttention() {
        let jobs = [
            job(state: .failed(.init(stage: .transcribing, message: "Offline"))),
            job(state: .queued),
            job(state: .ready)
        ]

        #expect(RecoveryPresentation.badgeCount(jobs) == 1)
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

    @Test func retryPresentationDistinguishesIdleQueuedAndProcessing() {
        #expect(RecoveryPresentation.retryState(for: .failed(.init(stage: .transcribing, message: "x"))) == .available)
        #expect(RecoveryPresentation.retryState(for: .queued) == .queued)
        #expect(RecoveryPresentation.retryState(for: .processing(stage: .postProcessing)) == .processing("Post-processing"))
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
        TranscriptionJob(
            id: UUID(), kind: .recovery, source: .init(reference: "/tmp/recovery.wav"),
            state: state, progress: 0, createdAt: now, updatedAt: now,
            startedAt: nil, completedAt: nil, expiresAt: nil, result: nil,
            needsSourceCleanup: false, sourceCleanupError: nil
        )
    }
}
