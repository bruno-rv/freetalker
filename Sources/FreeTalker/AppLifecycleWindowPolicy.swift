import AppKit
import Darwin
import Foundation

final class AppInstanceLease {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(path: String) -> AppInstanceLease? {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return AppInstanceLease(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

struct AppInstanceClaimResult {
    let lease: AppInstanceLease?
    let shouldTerminate: Bool
}

struct AppLaunchCandidate: Equatable {
    let processIdentifier: pid_t
    let launchDate: Date
}

@MainActor
enum AppLifecycleWindowPolicy {
    static var instanceLeasePath: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.bruno.freetalker"
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(bundleIdentifier)-\(getuid()).lock")
    }

    static func claimInstance(
        path: String,
        maxAttempts: Int,
        activateExistingOwner: () -> Bool,
        wait: () -> Void
    ) -> AppInstanceClaimResult {
        precondition(maxAttempts > 0)
        for attempt in 0..<maxAttempts {
            if let lease = AppInstanceLease.acquire(path: path) {
                return AppInstanceClaimResult(lease: lease, shouldTerminate: false)
            }
            _ = activateExistingOwner()
            if attempt < maxAttempts - 1 {
                wait()
            }
        }
        return AppInstanceClaimResult(lease: nil, shouldTerminate: true)
    }

    static func owner(in candidates: [AppLaunchCandidate]) -> AppLaunchCandidate? {
        candidates.min {
            if $0.launchDate != $1.launchDate {
                return $0.launchDate < $1.launchDate
            }
            return $0.processIdentifier < $1.processIdentifier
        }
    }

    static func existingOwner(for currentApplication: NSRunningApplication) -> NSRunningApplication? {
        guard let bundleIdentifier = currentApplication.bundleIdentifier else { return nil }

        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let candidates = applications.map {
            AppLaunchCandidate(
                processIdentifier: $0.processIdentifier,
                launchDate: $0.launchDate ?? .distantFuture
            )
        }
        guard let owner = owner(in: candidates),
              owner.processIdentifier != currentApplication.processIdentifier else {
            return nil
        }
        return applications.first { $0.processIdentifier == owner.processIdentifier }
    }

    static func configureSettingsWindow(_ window: NSWindow) {
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.level = .floating
    }
}
