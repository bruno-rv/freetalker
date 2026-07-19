import Foundation

struct Template: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var name: String
    var prompt: String

    /// LEGACY ONLY (PLAN.md PR A, item 5) — no longer appended to `builtIns` below. Spoken-
    /// command rules moved into the trusted system prompt (`CommandInstructionBuilder`), built by
    /// the post-processors, not the template. Kept verbatim so `migratingSpokenCommandRules` can
    /// strip this EXACT trailing text from every built-in-ID prompt's stored body — pristine
    /// installs match it exactly; edited installs that appended their own text after it still
    /// match this as a suffix, so only this known section is removed and every other edit is
    /// preserved. DO NOT change this string's content — the golden migration test asserts the
    /// exact delta.
    static let spokenCommandsSection = "This transcript may also contain Spoken Commands: English phrases spoken as instructions rather than words to transcribe, no matter what language the rest of the transcript is in (including Portuguese). Interpret them instead of transcribing the command words: \"new paragraph\" starts a new paragraph; \"new line\" breaks to a new line; \"quote\" ... \"unquote\" wraps the enclosed words in quotation marks; \"bullet point\" starts a bulleted list item; \"numbered list\" starts a numbered list item; \"all caps\" ... \"end caps\" uppercases the enclosed words; \"scratch that\" removes the most recent sentence or clause the speaker said immediately before the command. Phrases used descriptively rather than as instructions (for example, \"I added a new paragraph about pricing\") must be transcribed literally, exactly as spoken. When in doubt whether something is a command, transcribe it literally."

    /// The exact trailing substring `migratingSpokenCommandRules` strips from a built-in-ID
    /// prompt — the single space that joined it to the rest of the prompt, plus the legacy
    /// section itself.
    static let legacySpokenCommandsSuffix = " " + spokenCommandsSection

    static let builtIns: [Template] = [
        Template(
            id: "clean-dictation",
            name: "Clean Dictation",
            prompt: "Clean up this raw speech transcript. Fix punctuation and capitalization. Remove accidental disfluencies: filler words and hesitations (um, uh, hmm, like, you know, and their equivalents in the transcript's language), stutters, accidental word repetitions, and false starts. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\") — keep only the corrected version and drop the superseded statement entirely. Preserve intentional repetition, quoted text, names, and emphasis. Do not change the meaning, tone, or wording otherwise. Output only the cleaned text, no commentary."
        ),
        Template(
            id: "refined-message",
            name: "Refined Message",
            prompt: "Rewrite this raw speech transcript as a clear, well-structured chat message, in the same language as the transcript. Remove filler words, hesitations, stutters, and accidental repetitions. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\") — keep only their corrected intent and drop the superseded statement entirely. Preserve intentional repetition, quoted text, and names. Fix grammar and organize the ideas so they read as one coherent message. Keep the original meaning and tone. Output only the rewritten message, no commentary."
        ),
        Template(
            id: "refined-prompt",
            name: "Refined Prompt",
            prompt: "Rewrite this raw speech transcript as a clear, precise prompt suitable for sending to an AI assistant, in the same language as the transcript. Remove filler words, hesitations, and false starts. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\") — keep only the corrected intent and drop the superseded statement entirely. Make the intent explicit and organize multi-part requests into a short list if helpful. Preserve quoted text and names. Output only the rewritten prompt, no commentary."
        ),
        Template(
            id: "email",
            name: "Email",
            prompt: "Rewrite this raw speech transcript as a professional email body, in the same language as the transcript. Remove filler words, hesitations, and accidental repetitions. When the speaker corrects or contradicts something they said earlier — even in a previous sentence (e.g. \"it didn't work… actually, it works\") — keep only the corrected intent and drop the superseded statement entirely. Fix grammar and add appropriate structure (greeting/body/sign-off only if implied by content). Preserve names and quoted text. Output only the email body, no commentary."
        ),
        Template(
            id: "prompt-engineer",
            name: "Prompt Engineer",
            prompt: "Treat this raw speech transcript as a rough prompt, task description, or underperforming prompt, in the same language as the transcript. Rewrite it into an optimized prompt for Claude following Anthropic's best practices: open with a focused role sentence; state the task, output format, and every constraint as explicitly as a new colleague with no context would need; attach the \"why\" behind non-obvious constraints; for format- or tone-sensitive tasks, add 3-5 diverse examples in <example> tags; separate instructions, context, and input with descriptive XML tags, long documents first and the request last; phrase format instructions as what to do, not what to avoid; calibrate action language to the task — imperative and proactive for agentic work, conservative otherwise; add a self-check step when correctness matters; mark variable content with {{PLACEHOLDERS}}. Output exactly two sections: <optimized_prompt> with the complete rewritten prompt, then <design_notes> with 3-5 bullets on the rules applied and any assumptions made. No other commentary."
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

    /// PLAN.md PR A, item 5 — version-bumped migration (`TemplateStore`) that removes the legacy
    /// spoken-command rules from every BUILT-IN-ID template's stored prompt, now that those rules
    /// live in the trusted system prompt instead (`CommandInstructionBuilder`). User-created
    /// templates (an id not in `builtIns`) are never scanned or touched.
    ///
    /// Three outcomes per built-in-ID prompt:
    /// - Ends with the exact `legacySpokenCommandsSuffix` (pristine built-ins, and edited
    ///   built-ins whose OWN edits landed before this suffix — the common case, since users edit
    ///   the task instructions, not the trailing boilerplate) — that exact suffix is stripped,
    ///   every other edit is preserved verbatim.
    /// - Contains an unrecognized variant of the legacy section (a different wording, or the
    ///   suffix mid-string rather than at the end) — left INTACT, and its id is returned in
    ///   `unrecognizedIDs` so `TemplateStore` can surface a one-time Settings warning: legacy
    ///   rules are still active despite the toggle being off, and the user decides what to do.
    /// - No trace of the legacy section at all (already migrated, or a from-scratch built-in-ID
    ///   prompt that never had it) — left untouched, not flagged.
    static func migratingSpokenCommandRules(
        _ templates: [Template]
    ) -> (templates: [Template], changed: Bool, unrecognizedIDs: [String]) {
        let builtInIDs = Set(builtIns.map(\.id))
        var changed = false
        var unrecognizedIDs: [String] = []
        let migrated = templates.map { template -> Template in
            guard builtInIDs.contains(template.id) else { return template }
            if template.prompt.hasSuffix(legacySpokenCommandsSuffix) {
                changed = true
                var updated = template
                updated.prompt = String(template.prompt.dropLast(legacySpokenCommandsSuffix.count))
                return updated
            }
            if containsUnrecognizedLegacyCommandRuleVariant(template.prompt) {
                unrecognizedIDs.append(template.id)
            }
            return template
        }
        return (migrated, changed, unrecognizedIDs)
    }

    /// Heuristic for "this prompt still contains some form of the legacy spoken-command rules,
    /// but not the exact known suffix" — a case-insensitive scan for phrasing that only the
    /// legacy section (in any of its edited/reworded forms) would plausibly contain. Covers every
    /// distinctive clause of `spokenCommandsSection`, not just the heading and "scratch that": an
    /// edit that renames the heading and drops "scratch that" but keeps the paragraph/line/list/
    /// quote/caps instructions must still be caught (finding 5). False positives just mean an
    /// unrelated prompt gets a one-time (dismissible) warning it didn't need — never a silent
    /// miss, which is the unsafe direction here (leaving live legacy rules undetected).
    static func containsUnrecognizedLegacyCommandRuleVariant(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let markers = [
            "spoken command", "scratch that", "new paragraph", "new line",
            "bullet point", "numbered list", "all caps", "end caps",
            // Quote convention compound detector (Codex round-2 finding 3): the legacy section
            // only ever paired opener "quote" with closer "unquote", but an edited variant can
            // keep "quote" as the opener and reword the closer to "end quote" (the newer
            // system-prompt terminology) while dropping every other marker — either closer alone
            // must still flag it, since "quote" by itself is too common a word to use safely.
            "unquote", "end quote"
        ]
        return markers.contains { lowered.contains($0) }
    }

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
