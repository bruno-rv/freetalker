import Foundation
import WhisperKit

/// The approval fit-gate (PLAN.md PR B, item 4): decides whether a candidate vocabulary list
/// provably fits WhisperKit's real prompt-token window, independent of
/// `AppSettings.maxVocabularyCharacterBudget`/`maxVocabularyTerms` (those bound the manual-entry
/// UI/UX, not WhisperKit's actual `promptTokens` ceiling). `serializedPrompt` MUST stay byte-for-
/// byte identical to `WhisperKitEngine`'s own biasing serialization — both call this one function
/// — or the conservative byte-count bound below is unsound (see Round 1 advisor note: "one
/// serialization, shared").
enum VocabularyFitGate {
    /// The authoritative ceiling the fit-gate enforces — derived from WhisperKit's own
    /// `TextDecoder.prefill`, which retains only `(Constants.maxTokenContext / 2) - 1` prompt
    /// tokens before truncating (`WhisperKit/Core/TextDecoder.swift`'s `maxPromptLen`), NOT the
    /// full `Constants.maxTokenContext` (224) — a candidate list under 224 tokens can still be
    /// silently suffix-truncated by WhisperKit itself. Computed from the real constant (not a
    /// hardcoded literal) so an upstream WhisperKit change is caught by a type error/behavior
    /// change rather than silently drifting out of sync. Separate from, and stricter than,
    /// `AppSettings.maxVocabularyCharacterBudget` (600 bytes), which only bounds the raw
    /// manual-entry UI and was never a token-accurate limit. See Codex round 1 finding 2.
    static let tokenBudget = (Constants.maxTokenContext / 2) - 1

    /// The exact text WhisperKit will encode as `promptTokens` — leading space, `", "`-joined.
    static func serializedPrompt(_ terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }
        return " " + terms.joined(separator: ", ")
    }

    /// `serializedPrompt(terms).utf8.count`, computed algebraically instead of materializing the
    /// joined string: a leading space, each term's own UTF-8 byte length, and `count - 1` `", "`
    /// (2-byte) separators. Lets `EffectiveVocabulary.derive` track the conservative byte bound as
    /// a running total across appends instead of re-serializing the whole growing candidate list
    /// on every term (that was O(n²) for n approved terms). Must stay in lockstep with
    /// `serializedPrompt` — see this type's header; `VocabularyFitGateTests` pins the two together.
    static func serializedByteCount(_ terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        return 1 + terms.reduce(0) { $0 + $1.utf8.count } + 2 * (terms.count - 1)
    }

    /// `encode`, when supplied (tokenizer already loaded — never triggers a load), gives the
    /// exact token count of the serialized prompt; `nil` falls back to the conservative UTF-8
    /// byte-count bound. Every BPE token is at least 1 byte, so `bytes <= tokenBudget` guarantees
    /// `tokenCount <= tokenBudget` — the byte bound can refuse a term that would actually tokenize
    /// fine, never the inverse (silently-over-budget) failure. See PLAN.md PR B, item 4 and
    /// "Risks".
    static func fits(_ terms: [String], encode: ((String) -> Int)? = nil) -> Bool {
        guard !terms.isEmpty else { return true }
        let prompt = serializedPrompt(terms)
        if let encode {
            return encode(prompt) <= tokenBudget
        }
        return prompt.utf8.count <= tokenBudget
    }
}
