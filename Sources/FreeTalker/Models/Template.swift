import Foundation

struct Template: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var name: String
    var prompt: String

    static let spokenCommandsSection = "This transcript may also contain Spoken Commands: English phrases spoken as instructions rather than words to transcribe, no matter what language the rest of the transcript is in (including Portuguese). Interpret them instead of transcribing the command words: \"new paragraph\" starts a new paragraph; \"new line\" breaks to a new line; \"quote\" ... \"unquote\" wraps the enclosed words in quotation marks; \"bullet point\" starts a bulleted list item; \"numbered list\" starts a numbered list item; \"all caps\" ... \"end caps\" uppercases the enclosed words; \"scratch that\" removes the most recent sentence or clause the speaker said immediately before the command. Phrases used descriptively rather than as instructions (for example, \"I added a new paragraph about pricing\") must be transcribed literally, exactly as spoken. When in doubt whether something is a command, transcribe it literally."

    static let builtIns: [Template] = [
        Template(
            id: "clean-dictation",
            name: "Clean Dictation",
            prompt: "Clean up this raw speech transcript. Fix punctuation and capitalization. Remove accidental disfluencies: filler words and hesitations (um, uh, hmm, like, you know, and their equivalents in the transcript's language), stutters, accidental word repetitions, and false starts. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\") — keep only the corrected version and drop the superseded statement entirely. Preserve intentional repetition, quoted text, names, and emphasis. Do not change the meaning, tone, or wording otherwise. Output only the cleaned text, no commentary. " + spokenCommandsSection
        ),
        Template(
            id: "refined-message",
            name: "Refined Message",
            prompt: "Rewrite this raw speech transcript as a clear, well-structured chat message, in the same language as the transcript. Remove filler words, hesitations, stutters, and accidental repetitions. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\") — keep only their corrected intent and drop the superseded statement entirely. Preserve intentional repetition, quoted text, and names. Fix grammar and organize the ideas so they read as one coherent message. Keep the original meaning and tone. Output only the rewritten message, no commentary. " + spokenCommandsSection
        ),
        Template(
            id: "refined-prompt",
            name: "Refined Prompt",
            prompt: "Rewrite this raw speech transcript as a clear, precise prompt suitable for sending to an AI assistant, in the same language as the transcript. Remove filler words, hesitations, and false starts. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\") — keep only the corrected intent and drop the superseded statement entirely. Make the intent explicit and organize multi-part requests into a short list if helpful. Preserve quoted text and names. Output only the rewritten prompt, no commentary. " + spokenCommandsSection
        ),
        Template(
            id: "email",
            name: "Email",
            prompt: "Rewrite this raw speech transcript as a professional email body, in the same language as the transcript. Remove filler words, hesitations, and accidental repetitions. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\") — keep only the corrected intent and drop the superseded statement entirely. Fix grammar and add appropriate structure (greeting/body/sign-off only if implied by content). Preserve names and quoted text. Output only the email body, no commentary. " + spokenCommandsSection
        )
    ]

    static let defaultID = "clean-dictation"

    static let legacyPrompts: [String: [String]] = [
        "clean-dictation": [
            """
            Clean up this raw speech transcript: fix punctuation, capitalization, and remove filler \
            words (um, uh, like) and false starts. Do not change the meaning, tone, or wording otherwise. \
            Output only the cleaned text, no commentary.
            """,
            "Clean up this raw speech transcript. Fix punctuation and capitalization. Remove accidental disfluencies: filler words and hesitations (um, uh, hmm, like, you know, and their equivalents in the transcript's language), stutters, accidental word repetitions, and false starts. When the speaker corrects themselves mid-thought (e.g. \"I'll do A… actually, I'll do B\"), keep only the final version. Preserve intentional repetition, quoted text, names, and emphasis. Do not change the meaning, tone, or wording otherwise. Output only the cleaned text, no commentary.",
            "Clean up this raw speech transcript. Fix punctuation and capitalization. Remove accidental disfluencies: filler words and hesitations (um, uh, hmm, like, you know, and their equivalents in the transcript's language), stutters, accidental word repetitions, and false starts. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\"), keep only the corrected version and drop the superseded statement entirely. Preserve intentional repetition, quoted text, names, and emphasis. Do not change the meaning, tone, or wording otherwise. Output only the cleaned text, no commentary."
        ],
        "refined-message": [
            """
            Rewrite this raw speech transcript as a clear, well-structured chat message. Keep the \
            original meaning and the same language as the transcript. Fix grammar and remove filler words. \
            Output only the rewritten message, no commentary.
            """,
            "Rewrite this raw speech transcript as a clear, well-structured chat message, in the same language as the transcript. Remove filler words, hesitations, stutters, and accidental repetitions. When the speaker corrects or revises themselves mid-thought, keep only their final intent. Preserve intentional repetition, quoted text, and names. Fix grammar and organize the ideas so they read as one coherent message. Keep the original meaning and tone. Output only the rewritten message, no commentary.",
            "Rewrite this raw speech transcript as a clear, well-structured chat message, in the same language as the transcript. Remove filler words, hesitations, stutters, and accidental repetitions. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\"), keep only their corrected intent and drop the superseded statement entirely. Preserve intentional repetition, quoted text, and names. Fix grammar and organize the ideas so they read as one coherent message. Keep the original meaning and tone. Output only the rewritten message, no commentary."
        ],
        "refined-prompt": [
            """
            Rewrite this raw speech transcript as a clear, precise prompt suitable for sending to an AI \
            assistant. Keep the same language as the transcript. Make the intent explicit and organize \
            multi-part requests into a short list if helpful. Output only the rewritten prompt, no commentary.
            """,
            "Rewrite this raw speech transcript as a clear, precise prompt suitable for sending to an AI assistant, in the same language as the transcript. Remove filler words, hesitations, and false starts. When the speaker revises themselves mid-thought, keep only the final intent. Make the intent explicit and organize multi-part requests into a short list if helpful. Preserve quoted text and names. Output only the rewritten prompt, no commentary.",
            "Rewrite this raw speech transcript as a clear, precise prompt suitable for sending to an AI assistant, in the same language as the transcript. Remove filler words, hesitations, and false starts. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\"), keep only the corrected intent and drop the superseded statement entirely. Make the intent explicit and organize multi-part requests into a short list if helpful. Preserve quoted text and names. Output only the rewritten prompt, no commentary."
        ],
        "email": [
            """
            Rewrite this raw speech transcript as a professional email body, in the same language as the \
            transcript. Fix grammar, add appropriate structure (greeting/body/sign-off only if implied by \
            content), and remove filler words. Output only the email body, no commentary.
            """,
            "Rewrite this raw speech transcript as a professional email body, in the same language as the transcript. Remove filler words, hesitations, and accidental repetitions; when the speaker revises themselves, keep only the final intent. Fix grammar and add appropriate structure (greeting/body/sign-off only if implied by content). Preserve names and quoted text. Output only the email body, no commentary.",
            "Rewrite this raw speech transcript as a professional email body, in the same language as the transcript. Remove filler words, hesitations, and accidental repetitions. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\"), keep only the corrected intent and drop the superseded statement entirely. Fix grammar and add appropriate structure (greeting/body/sign-off only if implied by content). Preserve names and quoted text. Output only the email body, no commentary."
        ]
    ]

    static func upgradingBuiltIns(_ templates: [Template]) -> (templates: [Template], changed: Bool) {
        let currentPromptByID = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.id, $0.prompt) })
        var changed = false
        let upgraded = templates.map { template -> Template in
            guard let currentPrompt = currentPromptByID[template.id],
                  let legacyPromptsForID = legacyPrompts[template.id] else { return template }
            let trimmedPrompt = template.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedPrompt != currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                  legacyPromptsForID.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedPrompt }) else {
                return template
            }
            changed = true
            var upgradedTemplate = template
            upgradedTemplate.prompt = currentPrompt
            return upgradedTemplate
        }
        return (upgraded, changed)
    }
}
