import Foundation

/// A user-editable instruction set that transforms a Transcript into a Refined Output.
/// See CONTEXT.md: "Template".
struct Template: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var prompt: String
    var useCloud: Bool

    static let builtIns: [Template] = [
        Template(
            id: "clean-dictation",
            name: "Clean Dictation",
            prompt: """
            Clean up this raw speech transcript: fix punctuation, capitalization, and remove filler \
            words (um, uh, like) and false starts. Do not change the meaning, tone, or wording otherwise. \
            Output only the cleaned text, no commentary.
            """,
            useCloud: false
        ),
        Template(
            id: "refined-message",
            name: "Refined Message",
            prompt: """
            Rewrite this raw speech transcript as a clear, well-structured chat message. Keep the \
            original meaning and the same language as the transcript. Fix grammar and remove filler words. \
            Output only the rewritten message, no commentary.
            """,
            useCloud: false
        ),
        Template(
            id: "refined-prompt",
            name: "Refined Prompt",
            prompt: """
            Rewrite this raw speech transcript as a clear, precise prompt suitable for sending to an AI \
            assistant. Keep the same language as the transcript. Make the intent explicit and organize \
            multi-part requests into a short list if helpful. Output only the rewritten prompt, no commentary.
            """,
            useCloud: false
        ),
        Template(
            id: "email",
            name: "Email",
            prompt: """
            Rewrite this raw speech transcript as a professional email body, in the same language as the \
            transcript. Fix grammar, add appropriate structure (greeting/body/sign-off only if implied by \
            content), and remove filler words. Output only the email body, no commentary.
            """,
            useCloud: false
        )
    ]

    static let defaultID = "clean-dictation"
}
