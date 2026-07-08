import Foundation

/// Applies a Template to a Transcript to produce a Refined Output. See CONTEXT.md: "Post-Processor".
/// Implementations must never throw for "model unavailable" style conditions that the pipeline
/// can recover from by falling back to the raw transcript — see AppleFMProcessor.
protocol PostProcessor: Sendable {
    func process(transcript: String, template: Template) async throws -> String
}

/// The vocabulary-bias line appended to a post-processor's instructions so proper nouns/jargon
/// the user pre-registers in Settings survive the rewrite. Empty vocabulary yields an empty
/// string (no line added) — see SelfCheck's "empty vocab -> empty injection" contract.
func vocabularyInstruction(_ vocabulary: [String]) -> String {
    guard !vocabulary.isEmpty else { return "" }
    return "The transcript may reference these words/names — recognize and spell them exactly as given if relevant: \(vocabulary.joined(separator: ", "))."
}

/// Assembles a `PostProcessor`'s system instructions from the Template prompt, the vocabulary
/// hint (if any), and a processor-specific trailing directive. Centralized so every
/// `PostProcessor` implementation gets vocabulary bias for free instead of each one duplicating
/// the assembly — see AppleFMProcessor and CloudLLMProcessor.
func buildProcessorInstructions(template: Template, vocabulary: [String], trailing: String) -> String {
    var parts = [template.prompt]
    let hint = vocabularyInstruction(vocabulary)
    if !hint.isEmpty { parts.append(hint) }
    parts.append(trailing)
    return parts.joined(separator: "\n\n")
}
