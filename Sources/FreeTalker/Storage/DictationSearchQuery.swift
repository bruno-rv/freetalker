import Foundation

/// Pure query-construction helpers shared by the ONE dictation search path (`Database.search`,
/// PLAN.md F3.3) — reused by both the Library view's live search (`Database.searchDictations`)
/// and the Dictation History Quick Panel's bounded search, so FTS/LIKE semantics can never drift
/// between the two callers. No I/O, no SQLite handle — everything here is a plain string
/// transform, unit-testable without a database.
enum DictationSearchQuery {
    /// Hard ceiling on the raw query string accepted before it's ever handed to SQLite, in UTF-8
    /// bytes (not `String.count` — same reasoning as `AppSettings`' vocabulary bound: a
    /// combining-mark-heavy paste can stay under a character count while its byte size is huge).
    /// A pathological paste can't blow up FTS5 tokenization or force an oversized LIKE scan.
    static let maxQueryBytes = 500

    /// The `ESCAPE` character used by `likePattern(for:)`'s `LIKE` clause.
    static let likeEscapeCharacter: Character = "\\"

    /// Trims whitespace and clamps to `maxQueryBytes` UTF-8 bytes, cutting only at a `Character`
    /// (grapheme cluster) boundary so the result is always valid text.
    static func bounded(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxQueryBytes else { return trimmed }
        var byteCount = 0
        var cutIndex = trimmed.startIndex
        for index in trimmed.indices {
            let charByteCount = trimmed[index].utf8.count
            guard byteCount + charByteCount <= maxQueryBytes else { break }
            byteCount += charByteCount
            cutIndex = trimmed.index(after: index)
        }
        return String(trimmed[..<cutIndex])
    }

    /// FTS5 `MATCH` expression: the whole (already-bounded, trimmed) query quoted as ONE phrase
    /// literal, with embedded `"` doubled — FTS5's own string-literal escaping — so punctuation,
    /// unbalanced quotes, or FTS5 query-syntax characters (`^`, `*`, `:`, `-`, ...) in free-typed
    /// search text can never be interpreted as query syntax. A trailing `*` is appended OUTSIDE the
    /// closing quote to make the final token a prefix match, so live as-you-type search ("kuber"
    /// matches "Kubernetes") keeps working. The `*` is outside the phrase literal, so a `*` typed by
    /// the user stays inside the quotes and is still a literal character, never query syntax. See
    /// PLAN.md F3.3 ("accepted: loses advanced query syntax for v1").
    static func ftsMatchExpression(for query: String) -> String {
        let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"*"
    }

    /// `LIKE` pattern with `likeEscapeCharacter` escaped FIRST, then `%`/`_` — order matters: if
    /// `%`/`_` were escaped first, a literal escape character already present in the query would
    /// itself get re-escaped when the escape-character pass ran afterward, corrupting the
    /// pattern. Callers must add their own `ESCAPE '<likeEscapeCharacter>'` clause.
    static func likePattern(for query: String) -> String {
        let escapeString = String(likeEscapeCharacter)
        var escaped = query.replacingOccurrences(of: escapeString, with: escapeString + escapeString)
        escaped = escaped.replacingOccurrences(of: "%", with: escapeString + "%")
        escaped = escaped.replacingOccurrences(of: "_", with: escapeString + "_")
        return "%\(escaped)%"
    }
}
