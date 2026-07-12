import Foundation
import Testing
@testable import FreeTalker

@Suite("Recording destinations")
struct RecordingDestinationTests {
    @Test func scratchpadDestinationKeepsItsInsertionToken() {
        let token = ScratchpadInsertionToken(id: UUID())

        #expect(RecordingDestination.scratchpad(token) == .scratchpad(token))
        #expect(RecordingDestination.external != .scratchpad(token))
    }

    @Test func launcherStartDoesNotToggleAnActiveRecording() {
        #expect(AppCoordinator.launcherStartDecision(isRecording: false, isProcessing: false))
        #expect(!AppCoordinator.launcherStartDecision(isRecording: true, isProcessing: false))
        #expect(!AppCoordinator.launcherStartDecision(isRecording: false, isProcessing: true))
    }

    @MainActor @Test func lifecycleStartFailureNotifiesRouterAndResets() {
        let router = RouterProbe()
        let lifecycle = RecordingDestinationLifecycle(router: router)
        let token = ScratchpadInsertionToken(id: UUID())
        #expect(!lifecycle.begin(.scratchpad(token), start: { false }, failureMessage: { "start failed" }))
        #expect(lifecycle.currentDestination == nil)
        #expect(router.events == [.failure("start failed")])
    }

    @MainActor
    @Test func coordinatorDoesNotRetainScratchpadRouter() {
        weak var releasedRouter: RouterProbe?
        do {
            let router = RouterProbe()
            releasedRouter = router
            AppCoordinator.shared.scratchpadRecordingRouter = router
        }

        #expect(releasedRouter == nil)
        #expect(AppCoordinator.shared.scratchpadRecordingRouter == nil)
    }

    @MainActor
    @Test func lifecycleExternalCompletionRunsOnlyExternalSideEffects() throws {
        var externalCalls = 0
        let router = RouterProbe()

        let lifecycle = RecordingDestinationLifecycle(router: router)
        let accepted = try lifecycle.complete("external text", destination: .external) { externalCalls += 1 }

        #expect(accepted)
        #expect(externalCalls == 1)
        #expect(router.events.isEmpty)
    }

    @Test func scratchpadStopSkipsExternalSnapshotReads() {
        let token = ScratchpadInsertionToken(id: UUID())
        var reads = 0
        let scratchpad: Int? = AppCoordinator.externalStopSnapshot(for: .scratchpad(token)) {
            reads += 1
            return 42
        }
        #expect(scratchpad == nil)
        #expect(reads == 0)

        let external: Int? = AppCoordinator.externalStopSnapshot(for: .external) {
            reads += 1
            return 42
        }
        #expect(external == 42)
        #expect(reads == 1)
    }

    @MainActor @Test func lifecycleCompletionRecoversAfterWeakRouterDisappears() throws {
        let token = ScratchpadInsertionToken(id: UUID())
        let lifecycle = RecordingDestinationLifecycle(router: nil)
        let accepted = try lifecycle.complete("recover me", destination: .scratchpad(token)) {}
        #expect(!accepted)
        #expect(lifecycle.consumePending(for: token) == "recover me")
        #expect(lifecycle.pending(for: token) == nil)
    }

    @MainActor @Test func lifecycleCancellationNotifiesAndClearsRecovery() throws {
        let token = ScratchpadInsertionToken(id: UUID())
        let router = RouterProbe(acceptCompletion: false)
        let lifecycle = RecordingDestinationLifecycle(router: router)
        let accepted = try lifecycle.complete("discard", destination: .scratchpad(token)) {}
        #expect(!accepted)
        lifecycle.install(.scratchpad(token))
        var stopped = false
        lifecycle.cancel { stopped = true }
        #expect(stopped)
        #expect(lifecycle.currentDestination == nil)
        #expect(lifecycle.pending(for: token) == nil)
        #expect(router.events.last == .cancellation)
    }

    @MainActor @Test func asyncLifecycleRoutesExternalCompletionOnlyToExternalEffects() async throws {
        let lifecycle = RecordingDestinationLifecycle(router: RouterProbe())
        var inserted = 0
        var recorded = 0
        let (_, accepted) = try await lifecycle.runAsync(
            destination: .external,
            process: { "external" },
            text: { $0 },
            external: { _ in inserted += 1; recorded += 1 }
        )
        #expect(accepted)
        #expect(inserted == 1)
        #expect(recorded == 1)
    }

    @MainActor @Test func asyncLifecycleRoutesFailureAndCancellationToScratchpad() async {
        let router = RouterProbe()
        let lifecycle = RecordingDestinationLifecycle(router: router)
        let token = ScratchpadInsertionToken(id: UUID())
        do {
            _ = try await lifecycle.runAsync(
                destination: .scratchpad(token), process: { throw ProbeError.failed },
                text: { $0 as String }, external: { _ in }
            )
        } catch {}
        #expect(router.events == [.failure("failed")])

        lifecycle.install(.scratchpad(token))
        do {
            _ = try await lifecycle.runAsync(
                destination: .scratchpad(token), process: { throw CancellationError() },
                text: { $0 as String }, external: { _ in }
            )
        } catch {}
        #expect(router.events.last == .cancellation)
    }

    @MainActor @Test func asyncScratchpadRejectionStoresRecoveryWithoutExternalEffects() async throws {
        let token = ScratchpadInsertionToken(id: UUID())
        let lifecycle = RecordingDestinationLifecycle(router: RouterProbe(acceptCompletion: false))
        var externalCalls = 0
        let (_, accepted) = try await lifecycle.runAsync(
            destination: .scratchpad(token), process: { "scratch" }, text: { $0 },
            external: { _ in externalCalls += 1 }
        )
        #expect(!accepted)
        #expect(externalCalls == 0)
        #expect(lifecycle.pending(for: token) == "scratch")
    }
}

private enum ProbeError: Error, LocalizedError {
    case failed
    var errorDescription: String? { "failed" }
}

@MainActor
private final class RouterProbe: ScratchpadRecordingRouting {
    var events: [RecordingDestinationEvent] = []
    let acceptCompletion: Bool

    init(acceptCompletion: Bool = true) { self.acceptCompletion = acceptCompletion }
    func updatePreview(_ text: String?, for token: ScratchpadInsertionToken) { events.append(.preview(text)) }
    func completeRecording(_ text: String, for token: ScratchpadInsertionToken) -> Bool {
        events.append(.completion(text))
        return acceptCompletion
    }
    func cancelRecording(for token: ScratchpadInsertionToken) { events.append(.cancellation) }
    func failRecording(_ message: String, for token: ScratchpadInsertionToken) { events.append(.failure(message)) }
}
