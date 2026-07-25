import Foundation
import PackagePlugin

/// Runs scripts/generate-update-public-key.sh before every build of the FreeTalker target, so
/// Sources/FreeTalker/Update/UpdatePublicKey.swift is always regenerated from
/// keys/release-public-key.base64 — the single committed source of truth for the compiled-in
/// release-signing trust anchor (see scripts/lib/public-key-data-file.sh for why the data file
/// exists at all: parsing that value back out of hand-written Swift source, tried across three
/// review rounds, kept reopening new ways for a decoy declaration to slip past the extractor).
///
/// SwiftPM tracks `keys/release-public-key.base64` as this command's declared input, so it only
/// reruns when that file actually changes, and treats the generated Swift file as this target's
/// output — compiled straight into the FreeTalker module, never read from a bundle resource at
/// runtime, so the trust anchor cannot be swapped out of an already-installed app.
@main
struct GenerateUpdatePublicKey: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let repoRoot = context.package.directoryURL
        let dataFile = repoRoot.appending(path: "keys/release-public-key.base64")
        let generatorScript = repoRoot.appending(path: "scripts/generate-update-public-key.sh")
        let outputFile = context.pluginWorkDirectoryURL.appending(path: "UpdatePublicKey.swift")

        return [
            .buildCommand(
                displayName: "Generate UpdatePublicKey.swift from keys/release-public-key.base64",
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [generatorScript.path, dataFile.path, outputFile.path],
                inputFiles: [dataFile, generatorScript],
                outputFiles: [outputFile]
            )
        ]
    }
}
