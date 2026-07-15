import Darwin
import Foundation

enum FreeTalkerPaths {
    struct InvalidSmokeConfigurationError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }
    struct Paths: Sendable, Equatable {
        let applicationSupport: URL
        var jobsDatabase: URL { applicationSupport.appendingPathComponent("jobs.db") }
        var libraryDatabase: URL { applicationSupport.appendingPathComponent("library.db") }
        var snippetsDatabase: URL { jobsDatabase }
        var recoveryDirectory: URL {
            applicationSupport.appendingPathComponent("failed-dictations", isDirectory: true)
        }
        var mediaImportsDirectory: URL {
            applicationSupport.appendingPathComponent("media-imports", isDirectory: true)
        }
        var scratchpadDocument: URL { applicationSupport.appendingPathComponent("scratchpad.rtf") }
        var debugAudio: URL { applicationSupport.appendingPathComponent("last-dictation.wav") }
        var fluidAudioModels: URL {
            applicationSupport.appendingPathComponent("models/fluidaudio", isDirectory: true)
        }
        var all: [URL] {
            [applicationSupport, jobsDatabase, libraryDatabase, snippetsDatabase,
             recoveryDirectory, mediaImportsDirectory, scratchpadDocument, debugAudio,
             fluidAudioModels]
        }
    }

    enum Resolution: Sendable, Equatable {
        case production(Paths)
        case isolated(Paths)
        case invalidSmokeConfiguration(Paths, String)

        var paths: Paths {
            switch self {
            case .production(let paths), .isolated(let paths),
                 .invalidSmokeConfiguration(let paths, _): paths
            }
        }
        var configurationError: String? {
            guard case .invalidSmokeConfiguration(_, let message) = self else { return nil }
            return message
        }
    }

    private static let invalidSmokeRoot = URL(
        fileURLWithPath: "/dev/null/FreeTalker-invalid-smoke-configuration",
        isDirectory: true
    )

    static let resolution: Resolution = {
        let fallback = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("FreeTalker", isDirectory: true)
#if DEBUG
        return resolve(
            environment: ProcessInfo.processInfo.environment,
            fallback: fallback,
            isMountedVolume: isRootOnMountedDisposableVolume,
            debugBuild: true
        )
#else
        return .production(Paths(applicationSupport: fallback))
#endif
    }()

    static var configurationError: String? { resolution.configurationError }
    static var applicationSupport: URL { resolution.paths.applicationSupport }
    static var jobsDatabase: URL { resolution.paths.jobsDatabase }
    static var libraryDatabase: URL { resolution.paths.libraryDatabase }
    static var snippetsDatabase: URL { resolution.paths.snippetsDatabase }
    static var recoveryDirectory: URL { resolution.paths.recoveryDirectory }
    static var mediaImportsDirectory: URL { resolution.paths.mediaImportsDirectory }
    static var scratchpadDocument: URL { resolution.paths.scratchpadDocument }
    static var debugAudio: URL { resolution.paths.debugAudio }
    static var fluidAudioModels: URL { resolution.paths.fluidAudioModels }

    static func requireValidConfiguration() throws {
        if let configurationError {
            throw InvalidSmokeConfigurationError(message: configurationError)
        }
    }

    static func resolve(
        environment: [String: String],
        fallback: URL,
        isMountedVolume: (URL) -> Bool,
        hasSafeComponents: (URL) -> Bool = hasNoSymlinkComponents,
        debugBuild: Bool
    ) -> Resolution {
        let production = Paths(applicationSupport: fallback)
        guard debugBuild else { return .production(production) }
        let allow = environment["FREETALKER_ALLOW_ISOLATED_SMOKE"]
        let configuredRoot = environment["FREETALKER_SMOKE_ROOT"]
        guard allow != nil || configuredRoot != nil else { return .production(production) }
        guard allow == "1", let raw = configuredRoot,
              raw.hasPrefix("/"), !raw.split(separator: "/").contains("..") else {
            return invalidResolution("Invalid DEBUG smoke isolation configuration")
        }
        let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        guard root.path.hasPrefix("/Volumes/"), isMountedVolume(root),
              hasSafeComponents(root) else {
            return invalidResolution("DEBUG smoke root is not a safe mounted volume path")
        }
        return .isolated(Paths(applicationSupport: root))
    }

    static func resolveApplicationSupport(
        environment: [String: String],
        fallback: URL,
        isMountedVolume: (URL) -> Bool,
        hasSafeComponents: (URL) -> Bool = hasNoSymlinkComponents,
        debugBuild: Bool
    ) -> URL {
        resolve(
            environment: environment, fallback: fallback,
            isMountedVolume: isMountedVolume, hasSafeComponents: hasSafeComponents,
            debugBuild: debugBuild
        ).paths.applicationSupport
    }

    private static func invalidResolution(_ message: String) -> Resolution {
        .invalidSmokeConfiguration(Paths(applicationSupport: invalidSmokeRoot), message)
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
