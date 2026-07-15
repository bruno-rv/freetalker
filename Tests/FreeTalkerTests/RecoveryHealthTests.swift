import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryHealthTests {
    @Test("durable admission follows recovery health and verified storage")
    func durableAdmissionRules() {
        #expect(!RecoveryHealth.initializing.allowsCapture(requiresDurableJournal: true, admissionStorageHealthy: true))
        #expect(!RecoveryHealth.unavailable("database failed").allowsCapture(requiresDurableJournal: true, admissionStorageHealthy: true))
        #expect(!RecoveryHealth.degraded("one item failed").allowsCapture(requiresDurableJournal: true, admissionStorageHealthy: false))
        #expect(RecoveryHealth.degraded("one item failed").allowsCapture(requiresDurableJournal: true, admissionStorageHealthy: true))
        #expect(RecoveryHealth.healthy.allowsCapture(requiresDurableJournal: true, admissionStorageHealthy: true))
    }

    @Test("transient Voice Edit is independent of recovery storage health")
    func transientAdmissionRules() {
        for health in [RecoveryHealth.initializing, .unavailable("database failed"), .degraded("item failed"), .healthy] {
            #expect(health.allowsCapture(requiresDurableJournal: false, admissionStorageHealthy: false))
        }
    }

    @Test("store failure is unavailable and item failure is degraded")
    func reportProjection() {
        #expect(RecoveryHealth.resolve(storeFailure: "jobs.db is corrupt", itemFailures: []) == .unavailable("jobs.db is corrupt"))
        #expect(RecoveryHealth.resolve(storeFailure: nil, itemFailures: ["capture A: permission denied"]) == .degraded("capture A: permission denied"))
        #expect(RecoveryHealth.resolve(storeFailure: nil, itemFailures: []) == .healthy)
    }

    @Test("owned cleanup failure prevents a healthy projection")
    func ownedFailurePreventsHealthy() {
        #expect(RecoveryHealth.resolve(storeFailure: nil, itemFailures: [], ownedFailure: "cleanup failed") == .degraded("cleanup failed"))
    }

    @Test("warning projection keeps exact message and retry action")
    func warningProjection() {
        let warning = RecoveryHealthWarning(health: .degraded("capture A: permission denied"))
        #expect(warning?.message == "capture A: permission denied")
        #expect(warning?.actionTitle == "Retry Recovery Setup")
        #expect(RecoveryHealthWarning(health: .healthy) == nil)
        #expect(RecoveryHealthWarning(health: .initializing) == nil)
    }

    @Test("retry transitions through initializing before successful health")
    func retryTransition() {
        let degraded = RecoveryHealth.degraded("one item failed")
        #expect(degraded.beginRetry() == .initializing)
        #expect(RecoveryHealth.resolve(storeFailure: nil, itemFailures: []) == .healthy)
    }

    @Test("external and Scratchpad are blocked while Voice Edit remains transient")
    func destinationAdmissionMatrix() {
        for destination in [
            RecordingDestination.external,
            .scratchpad(ScratchpadInsertionToken(id: UUID())),
        ] {
            #expect(!RecoveryHealth.initializing.allowsCapture(
                requiresDurableJournal: destination.requiresDurableJournal,
                admissionStorageHealthy: true
            ))
            #expect(!RecoveryHealth.unavailable("disk full").allowsCapture(
                requiresDurableJournal: destination.requiresDurableJournal,
                admissionStorageHealthy: true
            ))
        }
        #expect(RecoveryHealth.unavailable("disk full").allowsCapture(
            requiresDurableJournal: false,
            admissionStorageHealthy: false
        ))
    }

    @Test("retry defers while capture or processing owns mutable recovery state")
    func retryDeferral() {
        var scheduler = RecoverySetupRetryScheduler()
        #expect(scheduler.request(isBusy: true) == .deferred)
        #expect(scheduler.becameIdle(isBusy: true) == .none)
        #expect(scheduler.becameIdle(isBusy: false) == .run)
        #expect(scheduler.becameIdle(isBusy: false) == .none)
    }

    @Test("durability finalization failure blocks admission until reconciliation")
    func finalizationFailurePolicy() {
        #expect(RecoveryFinalizationFailurePolicy.classify(
            ownershipTransitionCompleted: false,
            message: "jobs.db is busy"
        ) == .init(health: .unavailable("jobs.db is busy"), admissionStorageHealthy: false))
        #expect(RecoveryFinalizationFailurePolicy.classify(
            ownershipTransitionCompleted: true,
            message: "canonical audio is damaged"
        ) == .init(health: .degraded("canonical audio is damaged"), admissionStorageHealthy: true))
    }

    @Test("retry always installs the freshly opened and validated store")
    func freshStoreReplacement() throws {
        final class Store { let name: String; init(_ name: String) { self.name = name } }
        let old = Store("old")
        var validated: [String] = []
        let replacement = try RecoveryStoreRetry.openFresh(
            replacing: old,
            open: { Store("fresh") },
            validate: { validated.append($0.name) }
        )
        #expect(replacement.name == "fresh")
        #expect(validated == ["fresh"])
    }
}
