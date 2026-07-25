#!/bin/bash
# scripts/test-public-key-data-file.sh — regression tests for
# read_established_public_key_base64 (scripts/lib/public-key-data-file.sh), the single function
# scripts/release.sh, scripts/make-release-signing-key.sh, and
# scripts/generate-update-public-key.sh all use to read the release-signing public key.
#
# This is the design that replaced scripts/lib/public-key-extract.sh (deleted): Rounds 5, 6, and
# 7 each found a new way for shell code parsing hand-written Swift source
# (Sources/FreeTalker/Update/UpdatePublicKey.swift) to disagree with what the Swift compiler
# itself would compile — a decoy second declaration, one inside an inactive `#if`, one inside a
# block comment, a file truncated mid-literal. Every fix closed the exact shape of the last
# finding and opened a new one. keys/release-public-key.base64 holds ONLY the base64 value, with
# no Swift syntax in its format at all — every one of those attack shapes is tested below and
# shown to fail closed, not because this function specifically defends against Swift syntax, but
# because there is no privileged interpretation of ANY extra content: exactly one line, exactly
# one well-formed base64 token decoding to 32 bytes, or MALFORMED.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/public-key-data-file.sh
source "$REPO_ROOT/scripts/lib/public-key-data-file.sh"

FAILURES=0
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-data-file-test-XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $*"; }

VALID_KEY="0mX1eBHprb/TXBqWGAC9mpRmt9+pu/hCMdX2440U5Uk="
OTHER_VALID_KEY="$(openssl genpkey -algorithm ED25519 2>/dev/null | openssl pkey -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)"

# Asserts the function returns 0 (ESTABLISHED) and prints exactly $2.
assert_established() {
    local data_file="$1" expected="$2" desc="$3"
    local output status
    set +e
    output="$(read_established_public_key_base64 "$data_file" 2>/dev/null)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "$desc: expected ESTABLISHED (exit 0), got exit $status"
        return
    fi
    if [[ "$output" != "$expected" ]]; then
        fail "$desc: expected value '$expected', got '$output'"
        return
    fi
    pass "$desc"
}

# Asserts the function returns 0 (ABSENT) and prints nothing.
assert_absent() {
    local data_file="$1" desc="$2"
    local output status
    set +e
    output="$(read_established_public_key_base64 "$data_file" 2>/dev/null)"
    status=$?
    set -e
    if [[ "$status" -ne 0 || -n "$output" ]]; then
        fail "$desc: expected ABSENT (exit 0, empty), got exit $status output '$output'"
        return
    fi
    pass "$desc"
}

# Asserts the function returns nonzero (MALFORMED), prints nothing on stdout, and a message on
# stderr.
assert_malformed() {
    local data_file="$1" desc="$2"
    local stdout_output stderr_output status
    set +e
    stdout_output="$(read_established_public_key_base64 "$data_file" 2>"$FIXTURE/.stderr")"
    status=$?
    set -e
    stderr_output="$(cat "$FIXTURE/.stderr")"
    if [[ "$status" -eq 0 ]]; then
        fail "$desc: expected MALFORMED (nonzero exit), got exit 0 with output '$stdout_output'"
        return
    fi
    if [[ -n "$stdout_output" ]]; then
        fail "$desc: MALFORMED case printed a value on stdout ('$stdout_output') — a caller" \
            "using \"if ! X=\$(...)\" could still see a truthy-looking value"
        return
    fi
    if [[ -z "$stderr_output" ]]; then
        fail "$desc: MALFORMED case produced no message on stderr — a silent failure gives an" \
            "operator nothing to act on"
        return
    fi
    pass "$desc"
}

log "Legitimate case: file doesn't exist yet (fresh checkout before first key generation)"
assert_absent "$FIXTURE/absent.base64" "absent data file is ABSENT, not an error"

log "Legitimate case: exactly one well-formed value, one trailing newline"
printf '%s\n' "$VALID_KEY" >"$FIXTURE/valid.base64"
assert_established "$FIXTURE/valid.base64" "$VALID_KEY" "well-formed single-line value is ESTABLISHED"

log "Legitimate case: exactly one well-formed value, NO trailing newline"
printf '%s' "$VALID_KEY" >"$FIXTURE/valid-noeol.base64"
assert_established "$FIXTURE/valid-noeol.base64" "$VALID_KEY" "well-formed value without a trailing newline is still ESTABLISHED"

log "Truncated/empty source (Round-6/7 Finding 2's shape): file exists but is completely empty" \
    "— must be MALFORMED, never conflated with ABSENT (which would let a brand-new key be" \
    "generated over a real anchor without --rotate-established-key)"
: >"$FIXTURE/empty.base64"
assert_malformed "$FIXTURE/empty.base64" "empty file is MALFORMED, not ABSENT"

log "Truncated source: base64 cut off mid-token (never reaches a valid length or terminator)"
printf '%s' "${VALID_KEY:0:20}" >"$FIXTURE/truncated.base64"
assert_malformed "$FIXTURE/truncated.base64" "truncated mid-token value is MALFORMED"

log "Decoy second 'base64 declaration' (Round-7 Finding 1's shape): two candidate values, one" \
    "per line — must be rejected outright, never silently resolved to either the first or the" \
    "last one"
printf '%s\n%s\n' "$VALID_KEY" "$OTHER_VALID_KEY" >"$FIXTURE/decoy-two-values.base64"
assert_malformed "$FIXTURE/decoy-two-values.base64" "two-value (decoy) file is MALFORMED, not silently resolved"

log "Round-7 Finding 1's shape, demonstrated impossible by construction: content styled to look" \
    "like it's hiding a decoy inside an inactive '#if' block, the way the old Swift-parsing" \
    "extractor could be fooled by one — there is no '#if' concept in this file format, so this" \
    "is just extra content around the value and is rejected exactly like any other garbage"
printf '#if false\n%s\n#endif\n%s\n' "$OTHER_VALID_KEY" "$VALID_KEY" >"$FIXTURE/fake-if.base64"
assert_malformed "$FIXTURE/fake-if.base64" "content resembling an inactive #if block is MALFORMED, not selectively parsed"

log "Round-7 Finding 1's shape, demonstrated impossible by construction: content styled to look" \
    "like it's hiding a decoy inside a Swift block comment — again, no comment concept exists" \
    "in this format, so it's just extra content, rejected outright"
printf '/* %s */\n%s\n' "$OTHER_VALID_KEY" "$VALID_KEY" >"$FIXTURE/fake-comment.base64"
assert_malformed "$FIXTURE/fake-comment.base64" "content resembling a block comment is MALFORMED, not selectively parsed"

log "A value that is not valid base64 of 32 bytes: well-formed base64 ALPHABET, wrong decoded length (31 bytes)"
SHORT_KEY="$(head -c 31 /dev/zero | openssl base64 -A)"
printf '%s\n' "$SHORT_KEY" >"$FIXTURE/short.base64"
assert_malformed "$FIXTURE/short.base64" "base64 value decoding to 31 bytes is MALFORMED"

log "A value that is not valid base64 of 32 bytes: well-formed base64 ALPHABET, wrong decoded length (33 bytes)"
LONG_KEY="$(head -c 33 /dev/zero | openssl base64 -A)"
printf '%s\n' "$LONG_KEY" >"$FIXTURE/long.base64"
assert_malformed "$FIXTURE/long.base64" "base64 value decoding to 33 bytes is MALFORMED"

log "A value that is not valid base64 at all: characters outside the base64 alphabet"
printf 'not-a-base64-value!!!\n' >"$FIXTURE/garbage.base64"
assert_malformed "$FIXTURE/garbage.base64" "non-base64 garbage is MALFORMED"

log "Extra trailing content after an otherwise well-formed value, on the SAME line (no newline" \
    "boundary at all — the shape a lenient 'grep the first base64-looking substring' extractor" \
    "would still silently accept)"
printf '%s extra-trailing-content\n' "$VALID_KEY" >"$FIXTURE/trailing-garbage.base64"
assert_malformed "$FIXTURE/trailing-garbage.base64" "value with trailing non-base64 content on the same line is MALFORMED"

log "Leading whitespace before an otherwise well-formed value"
printf '  %s\n' "$VALID_KEY" >"$FIXTURE/leading-space.base64"
assert_malformed "$FIXTURE/leading-space.base64" "value with leading whitespace is MALFORMED"

log "Multiple blank lines after the value"
printf '%s\n\n\n' "$VALID_KEY" >"$FIXTURE/trailing-blanks.base64"
assert_malformed "$FIXTURE/trailing-blanks.base64" "value followed by extra blank lines is MALFORMED"

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All public-key-data-file tests passed."
    exit 0
else
    echo "$FAILURES public-key-data-file test(s) failed." >&2
    exit 1
fi
