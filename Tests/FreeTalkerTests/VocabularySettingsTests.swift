import Foundation
import Testing
@testable import FreeTalker

@Suite("Vocabulary settings")
struct VocabularySettingsTests {
    @Test("editor presentation uses approved guidance")
    func approvedPresentation() {
        #expect(VocabularyEditorPresentation.placeholder ==
                "One term or phrase per line")
        #expect(VocabularyEditorPresentation.examples == [
            "OpenAI", "ScreenCaptureKit"
        ])
        #expect(VocabularyEditorPresentation.accessibilityLabel ==
                "Vocabulary terms")
        #expect(VocabularyEditorPresentation.minimumHeight == 100)
        #expect(VocabularyEditorPresentation.cornerRadius == 7)
    }

    @Test("raw vocabulary persists while normalized terms trim blanks")
    @MainActor
    func persistenceAndNormalization() throws {
        let suite = "VocabularySettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = " OpenAI \n\nScreenCaptureKit"

        let settings = AppSettings(defaults: defaults)
        settings.vocabularyText = raw

        #expect(defaults.string(forKey: "vocabularyText") == raw)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.vocabularyText == raw)
        #expect(reloaded.vocabulary == ["OpenAI", "ScreenCaptureKit"])
    }
}
