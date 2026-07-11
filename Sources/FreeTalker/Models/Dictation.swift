import Foundation

struct Dictation: Identifiable, Equatable {
    var id: Int64
    var timestamp: Date
    var language: String
    var templateName: String
    var transcript: String
    var refined: String
    var engine: String
    var sourceID: Int64?
}
