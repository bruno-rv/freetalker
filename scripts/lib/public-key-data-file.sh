# shellcheck shell=bash
# scripts/lib/public-key-data-file.sh — the ONE place that knows how to read
# keys/release-public-key.base64, the single source of truth for FreeTalker's release-signing
# public key. Sourced by scripts/release.sh, scripts/make-release-signing-key.sh, and
# scripts/generate-update-public-key.sh — never run directly.
#
# Rounds 5, 6, and 7 all found the SAME bug shape in the predecessor of this file
# (scripts/lib/public-key-extract.sh, deleted): every fix tried to make regex/brace-counting
# extraction of a `static let base64 = "..."` literal out of Sources/FreeTalker/Update/
# UpdatePublicKey.swift safe against Swift syntax the extractor didn't understand — a second
# `base64` declaration elsewhere in the file, one inside an inactive `#if`, one inside a block
# comment, a file truncated mid-literal. Each fix closed the exact shape of the last finding and
# opened a new one, because the real problem was never the regex: it was trying to reimplement a
# Swift parser in shell at all, against a file whose entire ambient syntax is attacker-shaped
# surface area no regex can safely characterize.
#
# The fix is to stop parsing Swift. keys/release-public-key.base64 holds ONLY the base64 value —
# no Swift syntax exists in this file's format at all, so there is nothing for a decoy
# declaration, an inactive #if, or a block comment to hide inside: any such content just becomes
# a second line or trailing garbage, which the checks below reject outright as MALFORMED rather
# than trying to interpret it. Sources/FreeTalker/Update/UpdatePublicKey.swift is no longer read
# by any of these scripts at all — it is GENERATED from this data file on every build (see
# scripts/generate-update-public-key.sh and Plugins/GenerateUpdatePublicKey), gitignored, and
# never hand-edited, so it cannot drift from this file by construction.
#
# Callers get exactly one of three outcomes from read_established_public_key_base64, matching
# the three states scripts/make-release-signing-key.sh must distinguish:
#   - file doesn't exist:                                exit 0, prints nothing (ABSENT)
#   - file holds exactly one well-formed base64 encoding
#     of a raw 32-byte value, one line, nothing else:     exit 0, prints the value (ESTABLISHED)
#   - anything else (empty, multiple lines/values,
#     truncated, not base64, wrong decoded length):        exit 1, prints nothing,
#                                                            message on stderr (MALFORMED)
# No caller may treat a nonzero return as either of the first two states.
read_established_public_key_base64() {
    local data_file="$1"
    if [[ ! -f "$data_file" ]]; then
        return 0
    fi

    # Slurps the file's exact bytes (unlike `content="$(cat "$data_file")"`, which would silently
    # strip every trailing newline via command substitution and hide a multi-blank-line file).
    local content
    IFS= read -r -d '' content <"$data_file" || true

    if [[ -z "$content" ]]; then
        echo "error: $data_file exists but is empty." >&2
        return 1
    fi

    # Count embedded newline bytes directly (bash parameter expansion, no external tool whose
    # line-counting semantics around a missing final newline vary by platform).
    local newlines_only="${content//[^$'\n']/}"
    local newline_count="${#newlines_only}"

    local value
    if [[ "$newline_count" -eq 0 ]]; then
        # No trailing newline at all — still exactly one value, still accepted.
        value="$content"
    elif [[ "$newline_count" -eq 1 && "$content" == *$'\n' ]]; then
        # Exactly the shape this tooling writes: one value, one trailing newline.
        value="${content%$'\n'}"
    else
        echo "error: $data_file must contain exactly one base64 value and nothing else — found" >&2
        echo "a second line, a decoy value, or other trailing content beyond a single trailing" >&2
        echo "newline. Refusing to guess which value is the real one." >&2
        return 1
    fi

    if [[ -z "$value" ]]; then
        echo "error: $data_file exists but is empty." >&2
        return 1
    fi

    if [[ ! "$value" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
        echo "error: $data_file's content is not a single well-formed base64 token (only" >&2
        echo "A-Za-z0-9+/ and up to two trailing '=' characters are allowed — no comments, no" >&2
        echo "whitespace, no Swift syntax of any kind)." >&2
        return 1
    fi

    local raw_byte_count
    raw_byte_count="$(printf '%s' "$value" | openssl base64 -A -d 2>/dev/null | wc -c | tr -d ' ')"
    if [[ -z "$raw_byte_count" || "$raw_byte_count" -ne 32 ]]; then
        echo "error: $data_file's value must decode to exactly 32 raw bytes (a raw Ed25519" >&2
        echo "public key); got ${raw_byte_count:-0}." >&2
        return 1
    fi

    printf '%s\n' "$value"
    return 0
}
