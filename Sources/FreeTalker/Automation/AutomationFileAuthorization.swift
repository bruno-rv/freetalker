import Foundation

/// Codex round-1 Finding 2 (HIGH, confused-deputy file read): FreeTalker is unsandboxed, so a
/// sandboxed or TCC-restricted caller could otherwise hand `transcribe` a path under
/// Documents/Desktop it can't read itself and get the contents back transcribed. The
/// `automationEnabled` toggle grants no per-file authority — only a file inside the user's
/// explicitly chosen Automation folder (Settings → Privacy → Automation) may be read.
///
/// Pure and `nonisolated` so it's testable without `AppSettings`'s `@MainActor` isolation or a
/// running app.
enum AutomationFileAuthorization {
    /// Resolves `requested` to its canonical (symlink-free, standardized) path and verifies that
    /// path is contained within `automationFolderPath`, itself canonicalized the same way — so a
    /// symlink planted *inside* the folder that points outside it is refused, and so is a symlink
    /// standing in for the configured folder itself. Symlinks are resolved BEFORE the containment
    /// comparison, never after.
    ///
    /// Returns the canonical URL to use for every check downstream of this one (regular-file,
    /// size, `MediaImportService.isSupported`, and the actual import) — never the caller-supplied
    /// URL, so nothing downstream re-introduces the symlink this function just resolved away.
    static func authorize(_ requested: URL, automationFolderPath: String?) throws -> URL {
        guard let automationFolderPath, !automationFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.automationFolderNotConfigured
        }
        let canonicalFolder = URL(fileURLWithPath: automationFolderPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalRequested = requested
            .resolvingSymlinksInPath()
            .standardizedFileURL

        var folderPath = canonicalFolder.path
        if !folderPath.hasSuffix("/") { folderPath += "/" }
        guard canonicalRequested.path.hasPrefix(folderPath) else {
            throw AutomationError.fileNotAuthorized
        }
        return canonicalRequested
    }
}
