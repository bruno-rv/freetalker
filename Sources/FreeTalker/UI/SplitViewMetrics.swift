import CoreGraphics

struct SplitViewWidthSpec: Equatable, Sendable {
    let minimum: CGFloat
    let ideal: CGFloat
    let maximum: CGFloat
}

enum SplitViewMetrics {
    static let detailMinimum: CGFloat = 320

    static let libraryMaster = SplitViewWidthSpec(minimum: 260, ideal: 300, maximum: 360)
    static let importsMaster = SplitViewWidthSpec(minimum: 280, ideal: 320, maximum: 360)
    static let snippetsMaster = SplitViewWidthSpec(minimum: 180, ideal: 220, maximum: 260)
    static let templatesMaster = SplitViewWidthSpec(minimum: 160, ideal: 200, maximum: 260)

    static let masterPaneSpecs = [libraryMaster, importsMaster, snippetsMaster, templatesMaster]
}
