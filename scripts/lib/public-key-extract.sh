# shellcheck shell=bash
# scripts/lib/public-key-extract.sh — the ONE place that knows how to read and write the
# compiled-in Ed25519 public key in Sources/FreeTalker/Update/UpdatePublicKey.swift.
# Sourced by scripts/release.sh and scripts/make-release-signing-key.sh — never run directly.
#
# scripts/release.sh (twice — the live tree's key, and BUILD_COMMIT's own pristine key read from
# an isolated worktree) and scripts/make-release-signing-key.sh (to decide whether an anchor is
# already established, and to write a new one) all need to agree EXACTLY on what "the
# compiled-in key" means for a given UpdatePublicKey.swift — round-6 finding 1. A naive
# `sed 's/.*base64 = "\(...\)".*'` is greedy and unanchored: for a line like
# `static let base64 = "A" // base64 = "B"` it silently returns the LAST match on the line (B)
# even though Swift only ever compiles the FIRST quoted literal (A). Signing with B then passes
# every comparison here (since every comparison used the same wrong sed) while every
# already-built A-pinned client rejects the release outright.
#
# Fixed by anchoring extraction to the exact `static let base64 = "..."` declaration and
# requiring exactly ONE well-formed match complete on its own line (a trailing decoy like the
# example above has non-whitespace after the closing quote, so it never matches at all) — plus a
# whole-file brace-balance sanity check. The balance check is what closes round-6 finding 2's
# other shape: a file truncated right after an otherwise complete, well-formed assignment line
# (so the single-line check alone would miss it) leaves `{`/`}` unbalanced and is caught, without
# coupling this check to the exact prose/comments of the generated file (which could reasonably
# change over time without the file becoming untrustworthy).
#
# Callers get exactly one of three outcomes from extract_compiled_public_key_base64, matching
# the three states scripts/make-release-signing-key.sh must distinguish:
#   - file doesn't exist:                              exit 0, prints nothing (ABSENT — nothing yet)
#   - file has one well-formed, balanced declaration V: exit 0, prints V      (ESTABLISHED)
#   - anything else (exists but doesn't parse cleanly):  exit 1, prints nothing, message on stderr
#                                                                             (MALFORMED — fail closed)
# No caller may treat a nonzero return as either of the first two states.

STRICT_BASE64_LINE_PATTERN='^[[:space:]]*static let base64 = "[A-Za-z0-9+/]*=?=?"[[:space:]]*$'

# Writes the exact, canonical UpdatePublicKey.swift content for a given base64 value to $2. The
# ONLY place this template is defined: scripts/make-release-signing-key.sh calls this to write
# the real file, and extract_compiled_public_key_base64 below calls it (with a candidate value
# read from an existing file) to verify that file is really what this script would have
# produced, not something hand-edited, decoyed, or truncated.
write_compiled_public_key_swift() {
    local public_key_base64="$1" out_file="$2"
    cat >"$out_file" <<EOF
import CryptoKit
import Foundation

/// The public half of the Ed25519 release-signing keypair (see
/// scripts/make-release-signing-key.sh). Compiled into every build — this is the trust anchor
/// \`UpdateSignatureVerifier\` checks a downloaded release's signature against. It is independent
/// of any machine-local keychain trust. The matching private key never leaves the release
/// signer's machine; regenerating this file with a new keypair is a breaking change for every
/// already-built app, since it can only ever trust the ONE public key it was compiled with.
enum UpdatePublicKey {
    static let base64 = "$public_key_base64"

    static var current: Curve25519.Signing.PublicKey? { Self.parse(base64: base64) }

    /// Pulled out of \`current\` so tests can exercise the exact parsing/validation logic
    /// (length check, \`CryptoKit\` construction) against both this real compiled-in key and
    /// deliberately invalid inputs, without needing a second compiled-in constant.
    static func parse(base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: base64), raw.count == 32,
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return nil }
        return key
    }
}
EOF
}

# Prints the compiled-in base64 public key from $1 on stdout and returns 0 if $1 doesn't exist,
# or has exactly one well-formed `static let base64 = "..."` line in a brace-balanced file (in
# which case that value is printed). Returns 1 (nothing on stdout, a message on stderr)
# otherwise — never guesses which of several candidate values is the real one, and never treats
# corrupted, truncated, or hand-edited source as either "nothing established" or "a trustworthy
# anchor."
extract_compiled_public_key_base64() {
    local swift_file="$1"
    if [[ ! -f "$swift_file" ]]; then
        return 0
    fi

    local strict_matches strict_count=0
    strict_matches="$(grep -E "$STRICT_BASE64_LINE_PATTERN" "$swift_file" || true)"
    if [[ -n "$strict_matches" ]]; then
        strict_count="$(printf '%s\n' "$strict_matches" | wc -l | tr -d ' ')"
    fi

    if [[ "$strict_count" -eq 0 ]]; then
        if ! grep -qE 'base64[[:space:]]*=' "$swift_file"; then
            # Nothing that even looks like an attempt to declare this field — treat exactly
            # like a missing file: nothing has been established here.
            return 0
        fi
        echo "error: $swift_file exists but has no single, well-formed" >&2
        echo "'static let base64 = \"...\"' assignment complete on its own line — this looks" >&2
        echo "truncated or hand-edited, not something this tooling produced. Refusing to guess" >&2
        echo "at a value." >&2
        return 1
    fi
    if [[ "$strict_count" -gt 1 ]]; then
        echo "error: $swift_file has $strict_count lines that each look like a complete" >&2
        echo "'static let base64 = \"...\"' assignment — refusing to guess which one Swift" >&2
        echo "actually compiles." >&2
        return 1
    fi

    # The ONE assignment line is well-formed on its own — but a file truncated right after it
    # (missing the rest of the enum body and its closing brace) would still pass that check
    # alone. `{`/`}` counts that don't match, or don't appear at all, mean the file isn't a
    # complete Swift source this tooling could have produced — refuse to trust it rather than
    # silently reporting "nothing to do" over a broken file.
    local open_braces close_braces
    open_braces="$(grep -o '{' "$swift_file" | wc -l | tr -d ' ')"
    close_braces="$(grep -o '}' "$swift_file" | wc -l | tr -d ' ')"
    if [[ "$open_braces" -eq 0 || "$open_braces" != "$close_braces" ]]; then
        echo "error: $swift_file has a well-formed base64 assignment line, but its braces are" >&2
        echo "unbalanced ($open_braces '{' vs $close_braces '}') — this looks like a truncated" >&2
        echo "or otherwise incomplete file, not something this tooling produced. Refusing to" >&2
        echo "treat it as a valid established anchor." >&2
        return 1
    fi

    printf '%s\n' "$strict_matches" | sed -E 's/^[[:space:]]*static let base64 = "([A-Za-z0-9+/]*=?=?)"[[:space:]]*$/\1/'
    return 0
}
