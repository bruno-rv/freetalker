enum LauncherEdge: String, CaseIterable, Codable, Sendable {
    case left, right, top, bottom
}

struct NormalizedWindowPosition: Codable, Equatable, Sendable {
    let displayID: String?
    let x: Double
    let y: Double
}
