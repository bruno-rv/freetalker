import Foundation

enum LocalContextScope: String, CaseIterable, Codable, Sendable {
    case off
    case selectedText
    case focusedField
    case activeWindow
    case windowOCR
}

extension LocalContextScope {
    var displayName: String {
        switch self {
        case .off: "Off"
        case .selectedText: "Selected text"
        case .focusedField: "Focused field"
        case .activeWindow: "Active window"
        case .windowOCR: "Window + local OCR"
        }
    }
}
