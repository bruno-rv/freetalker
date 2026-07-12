import Testing
@testable import FreeTalker

@Suite("Output languages")
struct OutputLanguageTests {
    @Test func outputLanguagesHaveStableOrderAndRawValues() {
        #expect(OutputLanguage.allCases == [
            .sameAsSpoken, .english, .portuguese, .mandarinChinese,
            .hindi, .spanish, .standardArabic, .french, .german,
        ])
        #expect(OutputLanguage.allCases.map(\.rawValue) == [
            "same", "en", "pt", "zh-Hans", "hi", "es", "ar", "fr", "de",
        ])
    }

    @Test func outputLanguagesHaveExplicitDisplayAndPromptNames() {
        #expect(OutputLanguage.allCases.map(\.displayName) == [
            "Same as spoken", "English", "Portuguese", "Mandarin Chinese",
            "Hindi", "Spanish", "Standard Arabic", "French", "German",
        ])
        #expect(OutputLanguage.allCases.map(\.promptName) == [
            "the same language as the source", "English", "Portuguese",
            "Mandarin Chinese", "Hindi", "Spanish", "Standard Arabic",
            "French", "German",
        ])
        #expect(TranslationTarget.allCases.map(\.promptName) == [
            "English", "Portuguese", "Mandarin Chinese", "Hindi",
            "Spanish", "Standard Arabic", "French", "German",
        ])
    }

    @Test func invalidPersistedLanguageFallsBackToSameAsSpoken() {
        #expect(OutputLanguage.persisted(rawValue: "not-a-language") == .sameAsSpoken)
        #expect(OutputLanguage.persisted(rawValue: nil) == .sameAsSpoken)
    }

    @Test func sameAsSpokenBuildsOnlyPreservePolicy() {
        #expect(OutputLanguage.sameAsSpoken.processingPolicy == .preserveSource)
        #expect(OutputLanguage.portuguese.processingPolicy == .translate(to: .portuguese))
    }

    @Test func translationTargetsCannotRepresentSameAsSpoken() {
        #expect(TranslationTarget(rawValue: OutputLanguage.sameAsSpoken.rawValue) == nil)
        #expect(TranslationTarget.allCases.map(\.rawValue) == [
            "en", "pt", "zh-Hans", "hi", "es", "ar", "fr", "de",
        ])
    }
}
