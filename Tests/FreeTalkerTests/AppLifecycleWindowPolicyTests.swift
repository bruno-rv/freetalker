import AppKit
import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct AppLifecycleWindowPolicyTests {
    @Test func settingsWindowIsFullscreenPrimaryAndDoesNotJoinOtherSpacesOrApplications() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]

        AppLifecycleWindowPolicy.configureSettingsWindow(window)

        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!window.collectionBehavior.contains(.canJoinAllApplications))
        #expect(window.level == .normal)
    }

    @Test func settingsWindowJoinsOtherApplicationsFullScreenSpacesWithoutCoveringSystemPrompts() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        AppLifecycleWindowPolicy.configureFocusableUtilityWindow(window)

        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.canJoinAllApplications))
        #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.level == .normal)
    }

    @Test func settingsWindowRemovesFullScreenAuxiliaryBeforeJoiningOtherApplications() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.collectionBehavior = [.fullScreenAuxiliary]

        AppLifecycleWindowPolicy.configureFocusableUtilityWindow(window)

        #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.canJoinAllApplications))
    }

    @Test func settingsWindowRemovesFullScreenPrimaryBeforeJoiningOtherApplications() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.collectionBehavior = [.fullScreenPrimary]

        AppLifecycleWindowPolicy.configureFocusableUtilityWindow(window)

        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.canJoinAllApplications))
    }

    @Test func firstLifetimeClaimSucceedsAndSecondClaimFails() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try #require(AppInstanceLease.acquire(path: path))
        #expect(AppInstanceLease.acquire(path: path) == nil)
        withExtendedLifetime(first) {}
    }

    @Test func leasePublishesItsActualOwnerProcessIdentifier() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let lease = try #require(AppInstanceLease.acquire(path: path, ownerPID: 220))

        #expect(AppInstanceLease.ownerPID(path: path) == 220)
        withExtendedLifetime(lease) {}
    }

    @Test func releasedLifetimeClaimAllowsTakeover() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        var first = AppInstanceLease.acquire(path: path)
        guard first != nil else {
            Issue.record("Initial lease acquisition failed")
            return
        }
        #expect(AppInstanceLease.acquire(path: path) == nil)
        first = nil
        #expect(AppInstanceLease.acquire(path: path) != nil)
    }

    @Test func claimActivatesExistingOwnerBeforeGivingUp() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try #require(AppInstanceLease.acquire(path: path, ownerPID: 220))
        var activatedPIDs: [pid_t] = []

        let result = AppLifecycleWindowPolicy.claimInstance(
            path: path,
            maxAttempts: 2,
            activateExistingOwner: { activatedPIDs.append($0); return true },
            wait: {}
        )

        #expect(result.lease == nil)
        #expect(result.shouldTerminate)
        #expect(activatedPIDs == [220, 220])
        withExtendedLifetime(first) {}
    }

    @Test func newerLockWinnerIsActivatedInsteadOfOlderCandidate() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let newerOwner = try #require(AppInstanceLease.acquire(path: path, ownerPID: 220))
        var activatedPID: pid_t?

        _ = AppLifecycleWindowPolicy.claimInstance(
            path: path,
            maxAttempts: 1,
            activateExistingOwner: { activatedPID = $0; return true },
            wait: {}
        )

        #expect(activatedPID == 220)
        withExtendedLifetime(newerOwner) {}
    }

    @Test(arguments: ["", "not-a-pid", "0", "-1", "999999999999999999999"])
    func invalidOwnerRecordDoesNotActivate(_ contents: String) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owner = try #require(AppInstanceLease.acquire(path: path, ownerPID: 220))
        try contents.write(toFile: path, atomically: false, encoding: .utf8)
        var activations = 0

        _ = AppLifecycleWindowPolicy.claimInstance(
            path: path,
            maxAttempts: 1,
            activateExistingOwner: { _ in activations += 1; return true },
            wait: {}
        )

        #expect(activations == 0)
        withExtendedLifetime(owner) {}
    }

    @Test func currentProcessOwnerRecordDoesNotActivateSelf() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let owner = try #require(AppInstanceLease.acquire(path: path))
        var activations = 0

        _ = AppLifecycleWindowPolicy.claimInstance(
            path: path,
            maxAttempts: 1,
            activateExistingOwner: { _ in activations += 1; return true },
            wait: {}
        )

        #expect(activations == 0)
        withExtendedLifetime(owner) {}
    }

    @Test func claimTakesOverWhenExitingOwnerReleasesLeaseDuringRetry() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var first = AppInstanceLease.acquire(path: path)
        guard first != nil else {
            Issue.record("Initial lease acquisition failed")
            return
        }
        #expect(first != nil)

        let result = AppLifecycleWindowPolicy.claimInstance(
            path: path,
            maxAttempts: 2,
            activateExistingOwner: { _ in true },
            wait: { first = nil }
        )

        #expect(result.lease != nil)
        #expect(!result.shouldTerminate)
    }

    @Test func soleInstanceClaimIsSafe() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(AppInstanceLease.acquire(path: path) != nil)
    }

    @Test func activationPreservesHealthyHotKeyListener() {
        var recoveries = 0
        AppCoordinator.recoverHotKeyListeningIfNeeded(isListening: true) { recoveries += 1 }
        #expect(recoveries == 0)
    }

    @Test func activationRecoversDeadHotKeyListener() {
        var recoveries = 0
        AppCoordinator.recoverHotKeyListeningIfNeeded(isListening: false) { recoveries += 1 }
        #expect(recoveries == 1)
    }
}
