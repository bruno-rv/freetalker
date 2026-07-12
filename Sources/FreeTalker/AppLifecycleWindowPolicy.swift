import AppKit

struct AppLaunchCandidate: Equatable {
    let processIdentifier: pid_t
    let launchDate: Date
}

@MainActor
enum AppLifecycleWindowPolicy {
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
