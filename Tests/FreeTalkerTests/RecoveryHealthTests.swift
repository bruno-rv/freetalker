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
}
