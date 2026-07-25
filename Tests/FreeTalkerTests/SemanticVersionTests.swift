import Testing
@testable import FreeTalker

@Suite struct SemanticVersionTests {
    @Test func parsesCleanTagWithVPrefix() {
        let version = SemanticVersion(string: "v1.2.3")
        #expect(version == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func parsesWithoutVPrefix() {
        #expect(SemanticVersion(string: "1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func parsesGitDescribeDevSuffix() {
        // Exactly the shape `git describe --tags --always --dirty` produces between tags —
        // see Makefile's VERSION.
        #expect(SemanticVersion(string: "v1.2.3-4-gabc1234") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion(string: "v1.2.3-4-gabc1234-dirty") == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test func rejectsNonSemverStrings() {
        #expect(SemanticVersion(string: "") == nil)
        #expect(SemanticVersion(string: "not-a-version") == nil)
        #expect(SemanticVersion(string: "1.2") == nil)
        #expect(SemanticVersion(string: "1.2.3.4") == nil)
        // What `git describe` falls back to when there are no tags at all (the actual state of
        // this repo before its first release) — must not be silently misparsed as some version.
        #expect(SemanticVersion(string: "943fb44-dirty") == nil)
    }

    @Test func ordersByMajorThenMinorThenPatch() {
        #expect(SemanticVersion(major: 1, minor: 0, patch: 0) < SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion(major: 1, minor: 0, patch: 0) < SemanticVersion(major: 1, minor: 1, patch: 0))
        #expect(SemanticVersion(major: 1, minor: 1, patch: 0) < SemanticVersion(major: 1, minor: 1, patch: 1))
        #expect(!(SemanticVersion(major: 1, minor: 2, patch: 3) < SemanticVersion(major: 1, minor: 2, patch: 3)))
    }
}
