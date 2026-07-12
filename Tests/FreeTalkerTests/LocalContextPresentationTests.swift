import Testing
@testable import FreeTalker

@Suite @MainActor struct LocalContextPresentationTests {
    @Test func scopePresentationCopyIsExactAndRawValuesStayStable() {
        let expected: [(LocalContextScope, String, String, String)] = [
            (.off, "off", "None", "Does not read nearby text. The destination app may still be used for App Rules and automatic template selection."),
            (.selectedText, "selectedText", "Selected text", "Reads only the selected text in the destination app. Requires Accessibility permission."),
            (.focusedField, "focusedField", "Current text field", "Reads the full focused editable field, excluding secure fields. Requires Accessibility permission."),
            (.activeWindow, "activeWindow", "Visible text in current window", "Reads text exposed by the current window's accessibility tree. Secure content is excluded. Requires Accessibility permission."),
            (.windowOCR, "windowOCR", "Current window screenshot (OCR)", "Takes one screenshot of the destination window and reads it with Apple Vision. Requires Screen Recording permission; the image is discarded after OCR.")
        ]

        #expect(LocalContextScope.allCases.count == expected.count)
        for (scope, raw, name, explanation) in expected {
            #expect(scope.rawValue == raw)
            #expect(scope.displayName == name)
            #expect(scope.explanation == explanation)
        }
    }

    @Test func automaticTemplateHelpNamesPriorityChoicesAndFallback() {
        let help = SettingsView.automaticTemplateHelp

        #expect(help.contains("App Rule"))
        #expect(help.contains("Email"))
        #expect(help.contains("Refined Message"))
        #expect(help.contains("Clean Dictation"))
        #expect(help.contains("Refined Prompt"))
        #expect(help.contains("Active Template"))
    }
}
