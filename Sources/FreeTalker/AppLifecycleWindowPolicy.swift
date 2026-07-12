import AppKit
import Darwin
import Foundation

final class AppInstanceLease {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(path: String, ownerPID: pid_t = getpid()) -> AppInstanceLease? {
        guard ownerPID > 0 else { return nil }
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        guard publish(ownerPID: ownerPID, to: descriptor) else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            return nil
        }
        return AppInstanceLease(descriptor: descriptor)
    }

    static func ownerPID(path: String) -> pid_t? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0, count < buffer.count else { return nil }
        let value = String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int64(value), parsed > 0, parsed <= Int64(Int32.max) else { return nil }
        return pid_t(parsed)
    }

    private static func publish(ownerPID: pid_t, to descriptor: Int32) -> Bool {
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else { return false }
        let bytes = Array("\(ownerPID)\n".utf8)
        let wroteAll = bytes.withUnsafeBytes { rawBuffer -> Bool in
            guard var address = rawBuffer.baseAddress else { return false }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = write(descriptor, address, remaining)
                guard written > 0 else { return false }
                remaining -= written
                address = address.advanced(by: written)
            }
            return true
        }
        return wroteAll && fsync(descriptor) == 0
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

@MainActor
enum AppLifecycleWindowPolicy {
    static var instanceLeasePath: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "org.freetalker.app"
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(bundleIdentifier)-\(getuid()).lock")
    }

    static func claimInstance(
        path: String,
        maxAttempts: Int,
        activateExistingOwner: (pid_t) -> Bool,
        wait: () -> Void
    ) -> AppInstanceClaimResult {
        precondition(maxAttempts > 0)
        for attempt in 0..<maxAttempts {
            if let lease = AppInstanceLease.acquire(path: path) {
                return AppInstanceClaimResult(lease: lease, shouldTerminate: false)
            }
            if let ownerPID = AppInstanceLease.ownerPID(path: path), ownerPID != getpid() {
                _ = activateExistingOwner(ownerPID)
            }
            if attempt < maxAttempts - 1 {
                wait()
            }
        }
        return AppInstanceClaimResult(lease: nil, shouldTerminate: true)
    }

    static func existingOwner(processIdentifier: pid_t, for currentApplication: NSRunningApplication) -> NSRunningApplication? {
        guard processIdentifier > 0,
              processIdentifier != currentApplication.processIdentifier,
              let bundleIdentifier = currentApplication.bundleIdentifier,
              let owner = NSRunningApplication(processIdentifier: processIdentifier),
              owner.bundleIdentifier == bundleIdentifier else { return nil }
        return owner
    }

    static func configureSettingsWindow(_ window: NSWindow) {
        window.collectionBehavior.subtract([.fullScreenPrimary, .fullScreenAuxiliary])
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .canJoinAllApplications])
        window.level = .normal
    }
}
