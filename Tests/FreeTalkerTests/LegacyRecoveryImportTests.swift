import Foundation
import Testing
@testable import FreeTalker

@Suite struct LegacyRecoveryImportTests {
    @Test("legacy audio is hash deduplicated across files and reopen")
    func legacyAudioIsDeduplicatedPersistently() async throws {
        let fixture = try ReconciliationFixture()
        let audio = WAVEncoder.encode(samples: [0.25, -0.2, 0.1], sampleRate: 16_000)
        let first = fixture.root.appendingPathComponent("failed-2024-01-01-120000.wav")
        let duplicate = fixture.root.appendingPathComponent("failed-manual-copy-17.wav")
        try audio.write(to: first)
        try audio.write(to: duplicate)

        let initial = await fixture.reconciler().reconcile()
        #expect(initial.imported == 1)
        #expect(initial.duplicates == 1)
        #expect(initial.failed == 0)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: duplicate.path))

        let reopened = try fixture.reopen()
        let second = await reopened.reconciler().reconcile()
        #expect(second.imported == 0)
        #expect(second.duplicates == 2)
        #expect(try await reopened.store.jobs(kind: .recovery).count == 1)
    }

    @Test("registration retries at the exact same-session schedule")
    func registrationRetrySchedule() async throws {
        let recorder = RetryRecorder(failuresBeforeSuccess: 2)
        let retrier = RecoveryRegistrationRetrier(sleep: { delay in
            await recorder.record(delay)
        })
        try await retrier.run { try await recorder.attempt() }
        #expect(await recorder.delays == [.zero, .milliseconds(250), .seconds(1)])
        #expect(await recorder.attemptCount == 3)
    }
}

private actor RetryRecorder {
    private let failuresBeforeSuccess: Int
    private(set) var delays: [Duration] = []
    private(set) var attemptCount = 0

    init(failuresBeforeSuccess: Int) { self.failuresBeforeSuccess = failuresBeforeSuccess }
    func record(_ delay: Duration) { delays.append(delay) }
    func attempt() throws {
        attemptCount += 1
        if attemptCount <= failuresBeforeSuccess { throw CocoaError(.fileWriteUnknown) }
    }
}
