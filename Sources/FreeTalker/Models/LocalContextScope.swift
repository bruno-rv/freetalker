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
        case .off: "None"
        case .selectedText: "Selected text"
        case .focusedField: "Current text field"
        case .activeWindow: "Visible text in current window"
        case .windowOCR: "Current window screenshot (OCR)"
        }
    }

    var explanation: String {
        switch self {
        case .off:
            "Does not read nearby text. The destination app may still be used for App Rules and automatic template selection."
        case .selectedText:
            "Reads only the selected text in the destination app. Requires Accessibility permission."
        case .focusedField:
            "Reads the full focused editable field, excluding secure fields. Requires Accessibility permission."
        case .activeWindow:
            "Reads text exposed by the current window's accessibility tree. Secure content is excluded. Requires Accessibility permission."
        case .windowOCR:
            "Takes one screenshot of the destination window and reads it with Apple Vision. Requires Screen Recording permission; the image is discarded after OCR."
        }
    }
}
