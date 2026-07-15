import Foundation

enum FreeTalkerPaths {
    static let applicationSupport: URL = {
        let fallback = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("FreeTalker", isDirectory: true)
#if DEBUG
        return resolveApplicationSupport(
            environment: ProcessInfo.processInfo.environment,
            fallback: fallback,
            isMountedVolume: isRootOnMountedDisposableVolume,
            debugBuild: true
        )
#else
        return fallback
#endif
    }()

    static var jobsDatabase: URL { applicationSupport.appendingPathComponent("jobs.db") }
    static var libraryDatabase: URL { applicationSupport.appendingPathComponent("library.db") }
    static var recoveryDirectory: URL {
        applicationSupport.appendingPathComponent("failed-dictations", isDirectory: true)
    }
    static var debugAudio: URL { applicationSupport.appendingPathComponent("last-dictation.wav") }

    static func resolveApplicationSupport(
        environment: [String: String],
        fallback: URL,
        isMountedVolume: (URL) -> Bool,
        debugBuild: Bool
    ) -> URL {
        guard debugBuild,
              environment["FREETALKER_ALLOW_ISOLATED_SMOKE"] == "1",
              let raw = environment["FREETALKER_SMOKE_ROOT"],
              raw.hasPrefix("/"),
              !raw.split(separator: "/").contains("..") else { return fallback }
        let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix("/Volumes/"), isMountedVolume(root) else { return fallback }
        return root
    }

    private static func isRootOnMountedDisposableVolume(_ root: URL) -> Bool {
        let components = root.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return false }
        let volume = URL(fileURLWithPath: "/", isDirectory: true)
            .appendingPathComponent("Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: volume.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
