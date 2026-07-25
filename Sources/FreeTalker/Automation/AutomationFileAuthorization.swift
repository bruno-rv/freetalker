import Darwin
import Foundation

/// Codex round-1 Finding 2 (HIGH, confused-deputy file read): FreeTalker is unsandboxed, so a
/// sandboxed or TCC-restricted caller could otherwise hand `transcribe` a path under
/// Documents/Desktop it can't read itself and get the contents back transcribed. The
/// `automationEnabled` toggle grants no per-file authority — only a file inside the user's
/// explicitly chosen Automation folder (Settings → Privacy → Automation) may be read.
///
/// Codex round-2 Finding 1 (HIGH): a path STRING in `UserDefaults` is not a stable authority.
/// Two concrete defeats of the round-1 design: (a) after the folder is chosen, anything can rename
/// it away and drop a symlink to e.g. `~/Documents` at the same path — both sides canonicalize to
/// Documents and containment succeeds; (b) before FreeTalker even launches,
/// `defaults write org.freetalker.app automationFolderPath /` authorizes the entire disk. The
/// authority is now a bookmark (`AppSettings.automationFolderBookmark`) captured from the actual
/// directory the folder picker returned — bookmark resolution follows the real filesystem object
/// (its volume + file identity), not a mutable path string, so a rename/symlink swap at the old
/// path never redirects it. `AppSettings.automationFolderPath` is DISPLAY ONLY from here on; it is
/// never read for authorization.
///
/// Pure and `nonisolated` so it's testable without `AppSettings`'s `@MainActor` isolation or a
/// running app.
enum AutomationFileAuthorization {
    /// The canonical requested file and the canonical folder it was authorized against — the
    /// caller (`AutomationService`) needs both so `AutomationMediaStaging` can pin a file
    /// descriptor to the real, bookmark-resolved directory rather than re-deriving it from a path.
    struct AuthorizedFile {
        let url: URL
        let folder: URL
        /// Codex round-3 additional finding: `AutomationMediaStaging.openPinned` reopens `folder`
        /// by PATHNAME (it can't hold a descriptor open across this call, `stage`'s own async
        /// call, and everything in between). This is the device+inode identity `folder` had at
        /// THIS check, captured with `stat` — `openPinned` `fstat`s its own reopen and compares,
        /// so a same-user process that deletes/replaces the real directory object at that path in
        /// the gap is caught rather than silently trusted, even though the pathname reopen itself
        /// can't be made fully atomic without holding a descriptor open across that gap.
        let folderIdentity: FileIdentity
    }

    /// A filesystem object's device+inode pair — stable identity for a directory that a pathname
    /// alone can't provide (a pathname can be deleted and replaced by an unrelated object).
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        static func of(_ url: URL) throws -> FileIdentity {
            var info = stat()
            guard stat(url.path, &info) == 0 else { throw AutomationError.automationFolderUnavailable }
            return FileIdentity(device: info.st_dev, inode: info.st_ino)
        }
    }

    /// Resolves `automationFolderBookmark` to the real directory it was created from — rejecting a
    /// missing, unreadable, stale, or no-longer-a-directory bookmark outright (Codex round-2
    /// Finding 1: "reject a stale or replaced identity") — then resolves `requested` to its
    /// canonical (symlink-free, standardized) path and verifies that path is contained within the
    /// resolved folder, itself canonicalized the same way — so a symlink planted *inside* the
    /// folder that points outside it is refused, and so is a symlink standing in for the folder
    /// itself. Symlinks are resolved BEFORE the containment comparison, never after.
    ///
    /// Returns the canonical URL to use for every check downstream of this one — never the
    /// caller-supplied URL, so nothing downstream re-introduces the symlink this function just
    /// resolved away — alongside the canonical folder, so a caller can pin a file descriptor to it
    /// without re-resolving a path (Codex round-2 Finding 2).
    static func authorize(_ requested: URL, automationFolderBookmark: Data?) throws -> AuthorizedFile {
        guard let automationFolderBookmark else {
            throw AutomationError.automationFolderNotConfigured
        }

        var isStale = false
        let resolvedFolder: URL
        do {
            resolvedFolder = try URL(
                resolvingBookmarkData: automationFolderBookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw AutomationError.automationFolderUnavailable
        }
        guard !isStale else {
            throw AutomationError.automationFolderUnavailable
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AutomationError.automationFolderUnavailable
        }

        let canonicalFolder = resolvedFolder
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
        let folderIdentity = try FileIdentity.of(canonicalFolder)
        return AuthorizedFile(url: canonicalRequested, folder: canonicalFolder, folderIdentity: folderIdentity)
    }
}
