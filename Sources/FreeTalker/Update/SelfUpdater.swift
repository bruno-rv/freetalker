import AppKit
import Foundation

/// The app bundle is assembled by `make app` at the root of the cloned repo (see README),
/// so the repo is always the bundle's parent directory. `SelfUpdater` checks that repo for
/// commits ahead of `origin/main` and, on request, relaunches `scripts/self-update.sh` to
/// pull, rebuild, and reopen the app.
enum SelfUpdater {
    /// Outcome of a `check()` call, pure enough to drive UI without any git access.
    enum Availability: Equatable {
        case upToDate
        case available(behindCount: Int)
        case blockedByLocalChanges
        case unavailable(String)
    }

    struct CheckReport: Equatable {
        let availability: Availability
        let repoPath: String?
        let currentShortHash: String?
    }

    // MARK: Pure decision logic (unit-tested without git — see SelfUpdaterTests)

    /// Behind==0 wins regardless of dirty state: there is nothing to pull, so local changes
    /// don't block anything. Only a dirty tree with commits actually available blocks.
    static func evaluate(behindCount: Int, isDirty: Bool) -> Availability {
        guard behindCount > 0 else { return .upToDate }
        guard !isDirty else { return .blockedByLocalChanges }
        return .available(behindCount: behindCount)
    }

    static func parseBehindCount(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isDirty(porcelainOutput: String) -> Bool {
        !porcelainOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Git-backed check

    /// Runs the git subprocesses off the main thread; safe to `await` from `@MainActor` code
    /// — the caller resumes on its own actor once this returns.
    static func check() async -> CheckReport {
        await Task.detached(priority: .userInitiated) {
            let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
            guard let repoPath = resolveRepoToplevel(from: bundleParent) else {
                return CheckReport(
                    availability: .unavailable("Updates unavailable (app not running from its repo)."),
                    repoPath: nil,
                    currentShortHash: nil
                )
            }

            guard runGit(["fetch", "origin"], in: repoPath) != nil else {
                return CheckReport(
                    availability: .unavailable("Could not reach the git remote."),
                    repoPath: repoPath,
                    currentShortHash: nil
                )
            }

            guard
                let behindOutput = runGit(["rev-list", "--count", "HEAD..origin/main"], in: repoPath),
                let behindCount = parseBehindCount(behindOutput)
            else {
                return CheckReport(
                    availability: .unavailable("Could not determine update status."),
                    repoPath: repoPath,
                    currentShortHash: nil
                )
            }

            let statusOutput = runGit(["status", "--porcelain"], in: repoPath) ?? ""
            let shortHash = runGit(["rev-parse", "--short", "HEAD"], in: repoPath)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return CheckReport(
                availability: evaluate(behindCount: behindCount, isDirty: isDirty(porcelainOutput: statusOutput)),
                repoPath: repoPath,
                currentShortHash: shortHash
            )
        }.value
    }

    /// Spawns `scripts/self-update.sh` detached (not awaited) and terminates the app so the
    /// script's PID-wait unblocks. There is no return path — the script relaunches the app.
    @MainActor
    static func performUpdate(repoPath: String) {
        let scriptPath = repoPath + "/scripts/self-update.sh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), repoPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Process plumbing

    private static func resolveRepoToplevel(from directory: URL) -> String? {
        guard let output = runGit(["rev-parse", "--show-toplevel"], in: directory.path) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `git -C <directory> <arguments>`, discarding stderr. `nil` on spawn failure or
    /// non-zero exit — callers treat that as "couldn't determine," never as untrusted input.
    private static func runGit(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
