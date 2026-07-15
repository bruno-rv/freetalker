import Foundation

enum SmokeCheckpoint {
    enum Name: String, Sendable {
        case postJobCreate = "post-job-create"
        case postLibraryInsert = "post-library-insert"
        case postLibraryCommitted = "post-library-committed"
        case deleteClaim = "delete-claim"
        case cancelIntent = "cancel-intent"
    }

    static func shouldEmit(
        _ name: Name,
        environment: [String: String],
        applicationSupport: URL = FreeTalkerPaths.applicationSupport,
        debugBuild: Bool
    ) -> Bool {
        guard debugBuild,
              environment["FREETALKER_ALLOW_ISOLATED_SMOKE"] == "1",
              let root = environment["FREETALKER_SMOKE_ROOT"],
              root.hasPrefix("/Volumes/"),
              !root.split(separator: "/").contains(".."),
              applicationSupport.standardizedFileURL.path
                == URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path,
              let configured = environment["FREETALKER_SMOKE_CHECKPOINTS"] else {
            return false
        }
        return configured.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == name.rawValue
        }
    }

    static func hit(_ name: Name) {
#if DEBUG
        guard shouldEmit(
            name,
            environment: ProcessInfo.processInfo.environment,
            debugBuild: true
        ) else { return }
        name.rawValue.withCString { freetalker_smoke_checkpoint($0) }
#endif
    }
}

#if DEBUG
@_cdecl("freetalker_smoke_checkpoint")
@inline(never)
func freetalker_smoke_checkpoint(_ name: UnsafePointer<CChar>) {
    withExtendedLifetime(name) {}
}
#endif
