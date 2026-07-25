import Foundation
import Testing
@testable import FreeTalker

@Suite struct SelfUpdaterTests {
    @Test func evaluateReportsAvailableWhenManifestIsNewer() {
        let manifest = UpdateManifest(version: "v1.3.0", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef")
        let result = SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 2, patch: 0), manifest: manifest)
        #expect(result == .available(manifest: manifest))
    }

    @Test func evaluateReportsUpToDateWhenCurrentIsNewerOrEqual() {
        let manifest = UpdateManifest(version: "v1.2.0", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef")
        #expect(SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 2, patch: 0), manifest: manifest) == .upToDate)
        #expect(SelfUpdater.evaluate(current: SemanticVersion(major: 1, minor: 3, patch: 0), manifest: manifest) == .upToDate)
    }

    @Test func evaluateFailsClosedOnUnparsableManifestVersion() {
        let manifest = UpdateManifest(version: "not-a-version", assetURL: URL(string: "https://example.com/a.zip")!, sha256: "deadbeef")
        guard case .unavailable = SelfUpdater.evaluate(current: SemanticVersion(major: 0, minor: 0, patch: 0), manifest: manifest) else {
            Issue.record("expected .unavailable for an unparsable manifest version")
            return
        }
    }

    /// Cross-checks `SelfUpdater.sha256Hex` against the actual `shasum` binary
    /// `scripts/release.sh` shells out to — never a hand-invented expected digest.
    @Test func sha256HexMatchesTheRealShasumTool() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let payload = Data("FreeTalker self-update checksum test — \(UUID())".utf8)
        try payload.write(to: tempFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", tempFile.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let expected = output.split(separator: " ").first.map(String.init)

        #expect(SelfUpdater.sha256Hex(of: payload) == expected)
    }

    /// The real `dist/latest.json` produced by `scripts/release.sh v0.1.0 --dry-run` — not
    /// hand-invented, this is exactly what the release script writes.
    @Test func decodesTheManifestJSONShapeReleaseScriptWrites() throws {
        let json = """
        {
          "version": "v0.1.0",
          "assetURL": "https://github.com/bruno-rv/freetalker/releases/download/v0.1.0/FreeTalker-v0.1.0.app.zip",
          "sha256": "c1fc1ebc8e3d3c5194243090ac0f0207f62f880b38ad585d3320a36d1b49f9e7"
        }
        """
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.version == "v0.1.0")
        #expect(
            manifest.assetURL.absoluteString
                == "https://github.com/bruno-rv/freetalker/releases/download/v0.1.0/FreeTalker-v0.1.0.app.zip"
        )
        #expect(manifest.sha256 == "c1fc1ebc8e3d3c5194243090ac0f0207f62f880b38ad585d3320a36d1b49f9e7")
    }
}
