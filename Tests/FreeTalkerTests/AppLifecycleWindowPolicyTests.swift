import AppKit
import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct AppLifecycleWindowPolicyTests {
    @Test func oldestProcessOwnsGlobalHotKeys() {
        let launches = [
            AppLaunchCandidate(processIdentifier: 220, launchDate: Date(timeIntervalSince1970: 20)),
            AppLaunchCandidate(processIdentifier: 110, launchDate: Date(timeIntervalSince1970: 10))
        ]

        #expect(AppLifecycleWindowPolicy.owner(in: launches)?.processIdentifier == 110)
    }

    @Test func processIdentifierBreaksLaunchDateTiesDeterministically() {
        let launchDate = Date(timeIntervalSince1970: 10)
        let launches = [
            AppLaunchCandidate(processIdentifier: 220, launchDate: launchDate),
            AppLaunchCandidate(processIdentifier: 110, launchDate: launchDate)
        ]

        #expect(AppLifecycleWindowPolicy.owner(in: launches)?.processIdentifier == 110)
    }

    @Test func settingsWindowAppearsAcrossSpacesAndAboveFullScreenApps() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        AppLifecycleWindowPolicy.configureSettingsWindow(window)

        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.level == .floating)
    }

    @Test func firstLifetimeClaimSucceedsAndSecondClaimFails() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-lease-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try #require(AppInstanceLease.acquire(path: path))
        #expect(AppInstanceLease.acquire(path: path) == nil)
        withExtendedLifetime(first) {}
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
        let first = try #require(AppInstanceLease.acquire(path: path))
        var activations = 0

        let result = AppLifecycleWindowPolicy.claimInstance(
            path: path,
            maxAttempts: 2,
            activateExistingOwner: { activations += 1; return true },
            wait: {}
        )

        #expect(result.lease == nil)
        #expect(result.shouldTerminate)
        #expect(activations == 2)
        withExtendedLifetime(first) {}
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
            activateExistingOwner: { true },
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
