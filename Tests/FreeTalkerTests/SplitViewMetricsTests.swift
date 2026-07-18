import CoreGraphics
import Testing
@testable import FreeTalker

struct SplitViewMetricsTests {
    @Test func masterPaneSpecsAreFiniteAndOrdered() {
        for spec in SplitViewMetrics.masterPaneSpecs {
            #expect(spec.minimum.isFinite)
            #expect(spec.ideal.isFinite)
            #expect(spec.maximum.isFinite)
            #expect(spec.minimum <= spec.ideal)
            #expect(spec.ideal <= spec.maximum)
        }
    }

    @Test func masterPaneSpecsMatchEachSplitView() {
        #expect(SplitViewMetrics.libraryMaster == .init(minimum: 260, ideal: 300, maximum: 360))
        #expect(SplitViewMetrics.importsMaster == .init(minimum: 280, ideal: 320, maximum: 360))
        #expect(SplitViewMetrics.snippetsMaster == .init(minimum: 180, ideal: 220, maximum: 260))
        #expect(SplitViewMetrics.templatesMaster == .init(minimum: 160, ideal: 200, maximum: 260))
    }

    @Test func detailPaneHasSharedMinimumWidth() {
        #expect(SplitViewMetrics.detailMinimum == 320)
    }
}
