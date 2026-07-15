import Darwin
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
    static var fluidAudioModels: URL {
        applicationSupport.appendingPathComponent("models/fluidaudio", isDirectory: true)
    }

    static func resolveApplicationSupport(
        environment: [String: String],
        fallback: URL,
        isMountedVolume: (URL) -> Bool,
        hasSafeComponents: (URL) -> Bool = hasNoSymlinkComponents,
        debugBuild: Bool
    ) -> URL {
        guard debugBuild,
              environment["FREETALKER_ALLOW_ISOLATED_SMOKE"] == "1",
              let raw = environment["FREETALKER_SMOKE_ROOT"],
              raw.hasPrefix("/"),
              !raw.split(separator: "/").contains("..") else { return fallback }
        let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix("/Volumes/"), isMountedVolume(root),
              hasSafeComponents(root) else { return fallback }
        return root
    }

    private static func isRootOnMountedDisposableVolume(_ root: URL) -> Bool {
        let components = root.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return false }
        let volume = URL(fileURLWithPath: "/", isDirectory: true)
            .appendingPathComponent("Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
        let resolvedVolume = volume.resolvingSymlinksInPath().standardizedFileURL
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: []
        ) ?? []
        guard mounted.contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL == resolvedVolume
        }) else { return false }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        return resolvedRoot.path == resolvedVolume.path
            || resolvedRoot.path.hasPrefix(resolvedVolume.path + "/")
    }

    static func hasNoSymlinkComponents(_ root: URL) -> Bool {
        let components = root.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return false }
        let volume = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(components[2], isDirectory: true)
        return hasNoSymlinkComponents(root, beneath: volume)
    }

    static func hasNoSymlinkComponents(_ root: URL, beneath ancestor: URL) -> Bool {
        let root = root.standardizedFileURL
        let ancestor = ancestor.standardizedFileURL
        guard root.path == ancestor.path || root.path.hasPrefix(ancestor.path + "/") else {
            return false
        }
        var current = ancestor
        let relative = root.path.dropFirst(ancestor.path.count)
            .split(separator: "/").map(String.init)
        for component in [""] + relative {
            if !component.isEmpty {
                current.appendPathComponent(component, isDirectory: true)
            }
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        return current.resolvingSymlinksInPath().standardizedFileURL == root
    }
}
