import Foundation

enum LocalContextScope: String, CaseIterable, Codable, Sendable {
    case off
    case selectedText
    case focusedField
    case activeWindow
    case windowOCR
}
