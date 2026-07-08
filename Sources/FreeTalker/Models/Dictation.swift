import Foundation

/// One row of the Library: a past Dictation. See CONTEXT.md: "Library".
struct Dictation: Identifiable, Equatable {
    var id: Int64
    var timestamp: Date
    var language: String
    var templateName: String
    var transcript: String
    var refined: String
    var engine: String
    /// Set when this row was created via Re-process — the id of the original Dictation whose
    /// Transcript was reused. See CONTEXT.md: "Re-process".
    var sourceID: Int64?
}
