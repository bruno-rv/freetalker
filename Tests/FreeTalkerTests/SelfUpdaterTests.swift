import Foundation
import Testing
@testable import FreeTalker

@Suite struct SelfUpdaterTests {
    @Test func upToDateWinsRegardlessOfDirtyState() {
        #expect(SelfUpdater.evaluate(behindCount: 0, isDirty: false) == .upToDate)
        #expect(SelfUpdater.evaluate(behindCount: 0, isDirty: true) == .upToDate)
    }

    @Test func dirtyTreeBlocksAnAvailableUpdate() {
        #expect(SelfUpdater.evaluate(behindCount: 3, isDirty: true) == .blockedByLocalChanges)
    }

    @Test func cleanTreeWithCommitsBehindIsAvailable() {
        #expect(SelfUpdater.evaluate(behindCount: 3, isDirty: false) == .available(behindCount: 3))
    }

    @Test func parseBehindCountHandlesGitOutputWhitespace() {
        #expect(SelfUpdater.parseBehindCount("3\n") == 3)
        #expect(SelfUpdater.parseBehindCount("0\n") == 0)
        #expect(SelfUpdater.parseBehindCount("") == nil)
        #expect(SelfUpdater.parseBehindCount("not-a-number") == nil)
    }

    @Test func isDirtyReadsGitStatusPorcelainOutput() {
        #expect(SelfUpdater.isDirty(porcelainOutput: "") == false)
        #expect(SelfUpdater.isDirty(porcelainOutput: "   \n") == false)
        #expect(SelfUpdater.isDirty(porcelainOutput: " M Sources/FreeTalker/App.swift\n") == true)
    }
}
