#!/bin/bash
# scripts/test-make-release-signing-key.sh — regression tests for the resumability fix in
# scripts/make-release-signing-key.sh (Round-3 Finding 3's other half), plus the data-file
# design that replaced Swift-source parsing entirely (Rounds 5-7).
#
# Runs the REAL, unmodified scripts/make-release-signing-key.sh (copied byte-for-byte into an
# isolated fixture, never touching ~/.freetalker or the real repo's keys/release-public-key.base64)
# against fixture paths supplied via its own environment-variable overrides
# (FREETALKER_RELEASE_SIGNING_KEY, FREETALKER_RELEASE_SIGNING_KEY_DIR) — the exact same
# mechanism scripts/release.sh uses, and the exact same script file, not a re-derived stand-in.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $*"; }

# Reads the established public key straight off the data file — no parsing, no assumptions
# about what scripts/make-release-signing-key.sh itself considers well-formed. Used only to
# check the OUTCOME of a run in these tests; the actual read/validate logic under test is
# read_established_public_key_base64 (scripts/lib/public-key-data-file.sh), exercised only via
# the real script above.
read_data_file() {
    [[ -f "$1" ]] || return 0
    cat "$1"
}

derive_public_key_base64() {
    openssl pkey -in "$1" -pubout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | tail -c 32 | openssl base64 -A
}

make_fixture() {
    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-keygen-test-XXXXXX")"
    mkdir -p "$fixture/scripts/lib" "$fixture/keys" "$fixture/keypem"
    cp "$REPO_ROOT/scripts/make-release-signing-key.sh" "$fixture/scripts/make-release-signing-key.sh"
    chmod +x "$fixture/scripts/make-release-signing-key.sh"
    # make-release-signing-key.sh sources this relative to its OWN location (REPO_ROOT), so the
    # fixture needs its own copy too — the REAL file, never a re-derived stand-in.
    cp "$REPO_ROOT/scripts/lib/public-key-data-file.sh" "$fixture/scripts/lib/public-key-data-file.sh"
    echo "$fixture"
}

test_fresh_generation_produces_a_matching_pair() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Fresh run: no PEM, no established public key yet"
    local key_path="$fixture/keypem/release-signing-key.pem"
    local data_file="$fixture/keys/release-public-key.base64"
    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_path" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "fresh generation failed unexpectedly:"$'\n'"$output"
        return
    fi
    if [[ ! -f "$key_path" ]]; then
        fail "fresh generation didn't create the private key at $key_path"
        return
    fi
    local perms
    perms="$(stat -f '%Lp' "$key_path")"
    if [[ "$perms" != "600" ]]; then
        fail "private key mode is $perms, expected 600"
        return
    fi
    local derived established
    derived="$(derive_public_key_base64 "$key_path")"
    established="$(read_data_file "$data_file")"
    if [[ -z "$derived" || "$derived" != "$established" ]]; then
        fail "established public key ('$established') doesn't match the generated private key ('$derived')"
        return
    fi
    pass "fresh generation produced a matching private/public keypair, private key mode 600"
}

test_interrupted_run_resumes_without_regenerating_the_key() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Simulating Finding 3's exact interruption: PEM written, keys/release-public-key.base64" \
        "never updated"
    local key_path="$fixture/keypem/release-signing-key.pem"
    openssl genpkey -algorithm ED25519 -out "$key_path" 2>/dev/null
    chmod 600 "$key_path"
    local key_before
    key_before="$(cat "$key_path")"
    local data_file="$fixture/keys/release-public-key.base64"
    # No keys/release-public-key.base64 at all yet — the OLD buggy script treated "PEM exists"
    # alone as "nothing to do" and exited 0 here, leaving this file missing/stale forever.

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_path" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "resuming an interrupted run failed unexpectedly:"$'\n'"$output"
        return
    fi
    if [[ ! -f "$data_file" ]]; then
        fail "resumed run did not write $data_file at all — this is exactly Finding 3's bug: a" \
            "rerun exits successfully merely because the PEM exists, without ever making the" \
            "established public key correspond to it"
        return
    fi
    local key_after
    key_after="$(cat "$key_path")"
    if [[ "$key_after" != "$key_before" ]]; then
        fail "resuming regenerated the PRIVATE key — it must only rewrite" \
            "keys/release-public-key.base64 from the EXISTING key, never replace the key itself"
        return
    fi
    local derived established
    derived="$(derive_public_key_base64 "$key_path")"
    established="$(read_data_file "$data_file")"
    if [[ -z "$derived" || "$derived" != "$established" ]]; then
        fail "after resuming, established public key ('$established') still doesn't match the private key ('$derived')"
        return
    fi
    pass "resumed run wrote the missing keys/release-public-key.base64 to match the EXISTING key, without regenerating it"

    log "Re-running again now that everything matches must be a true no-op"
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_path" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "re-running once everything already matches failed unexpectedly:"$'\n'"$output"
        return
    fi
    if [[ "$output" != *"Nothing to do"* ]]; then
        fail "re-running once everything already matches did not report 'Nothing to do'; got:"$'\n'"$output"
        return
    fi
    if [[ "$(cat "$key_path")" != "$key_after" ]]; then
        fail "the idempotent re-run changed the private key"
        return
    fi
    pass "re-running once PEM and established key already match is a true no-op"
}

test_established_anchor_mismatch_is_refused_without_override() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-4 Finding 3: an ESTABLISHED public key (already trusted by real, already-built"
    log "installs) must NOT be silently overwritten just because a DIFFERENT valid key happens"
    log "to be at \$FREETALKER_RELEASE_SIGNING_KEY — the exact accident the finding describes"
    log "(env var pointing at the wrong file), reproduced with the REAL script establishing the"
    log "anchor first, not a hand-written fixture data file."

    local key_a="$fixture/keypem/key-a.pem"
    local key_b="$fixture/keypem/key-b.pem"
    local data_file="$fixture/keys/release-public-key.base64"

    # Establish key A as the anchor the same way a real first-time setup would: let the REAL
    # script generate it and write keys/release-public-key.base64 for it.
    FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" >/dev/null 2>&1
    local established_data_file_content
    established_data_file_content="$(cat "$data_file")"

    # A DIFFERENT, but perfectly valid, Ed25519 key ends up at the SAME env-var path.
    openssl genpkey -algorithm ED25519 -out "$key_b" 2>/dev/null
    local key_b_content_before
    key_b_content_before="$(cat "$key_b")"

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_b" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "the script silently rotated the established anchor to key B without --rotate-established-key"
        echo "$output"
        return
    fi
    if [[ "$output" != *"ESTABLISHED public key"* ]]; then
        fail "the script refused, but not with the expected established-anchor message; got:"$'\n'"$output"
        return
    fi
    if [[ "$output" != *"--rotate-established-key"* ]]; then
        fail "the refusal did not mention the override flag by name; got:"$'\n'"$output"
        return
    fi
    if [[ "$(cat "$data_file")" != "$established_data_file_content" ]]; then
        fail "keys/release-public-key.base64 (the established anchor, key A) was modified despite being refused"
        return
    fi
    if [[ "$(cat "$key_b")" != "$key_b_content_before" ]]; then
        fail "key B's PEM was modified — this script must never touch a key file it refuses to use"
        return
    fi
    pass "established anchor mismatch refused without --rotate-established-key; keys/release-public-key.base64 (key A) untouched"
}

test_established_anchor_mismatch_rotates_with_explicit_override() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-4 Finding 3: the SAME established-mismatch scenario, but with the explicit," \
        "clearly-named override — this must be the only way to proceed, and must actually work"

    local key_a="$fixture/keypem/key-a.pem"
    local key_b="$fixture/keypem/key-b.pem"
    local data_file="$fixture/keys/release-public-key.base64"

    FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" >/dev/null 2>&1
    openssl genpkey -algorithm ED25519 -out "$key_b" 2>/dev/null
    local key_b_content_before
    key_b_content_before="$(cat "$key_b")"

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_b" "$fixture/scripts/make-release-signing-key.sh" --rotate-established-key 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "--rotate-established-key did not proceed; got:"$'\n'"$output"
        return
    fi
    if [[ "$(cat "$key_b")" != "$key_b_content_before" ]]; then
        fail "rotating regenerated key B's PRIVATE key — it must only ever rewrite keys/release-public-key.base64"
        return
    fi
    local derived established
    derived="$(derive_public_key_base64 "$key_b")"
    established="$(read_data_file "$data_file")"
    if [[ -z "$derived" || "$derived" != "$established" ]]; then
        fail "after --rotate-established-key, established public key ('$established') doesn't match key B's ('$derived')"
        return
    fi
    pass "--rotate-established-key rotated the anchor to key B without touching either private key"
}

test_missing_pem_with_established_anchor_is_refused_without_override() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-5 Finding 1: an ESTABLISHED public key must be protected even when the configured"
    log "private-key PATH DOESN'T EXIST AT ALL — a typo in FREETALKER_RELEASE_SIGNING_KEY, a lost" \
        "key, or a fresh publisher workstation must not be treated as 'nothing established yet'" \
        "just because there's no file to compare against."

    local key_a="$fixture/keypem/key-a.pem"
    local missing_key="$fixture/keypem/does-not-exist.pem"
    local data_file="$fixture/keys/release-public-key.base64"

    # Establish key A as the anchor the same way a real first-time setup would.
    FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" >/dev/null 2>&1
    local established_data_file_content
    established_data_file_content="$(cat "$data_file")"

    if [[ -e "$missing_key" ]]; then
        fail "test setup bug: $missing_key unexpectedly exists"
        return
    fi

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$missing_key" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "the script silently generated a NEW key and rotated the established anchor merely" \
            "because the configured private-key path was missing"
        echo "$output"
        return
    fi
    if [[ "$output" != *"ESTABLISHED public key"* ]]; then
        fail "the script refused, but not with the expected established-anchor message; got:"$'\n'"$output"
        return
    fi
    if [[ "$output" != *"--rotate-established-key"* ]]; then
        fail "the refusal did not mention the override flag by name; got:"$'\n'"$output"
        return
    fi
    if [[ -e "$missing_key" ]]; then
        fail "the script created a new private key at $missing_key despite being refused"
        return
    fi
    if [[ "$(cat "$data_file")" != "$established_data_file_content" ]]; then
        fail "keys/release-public-key.base64 (the established anchor, key A) was modified despite being refused"
        return
    fi
    pass "missing PEM with an established anchor refused without --rotate-established-key;" \
        "no new key generated, keys/release-public-key.base64 (key A) untouched"
}

test_missing_pem_with_established_anchor_rotates_with_explicit_override() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-5 Finding 1: the SAME missing-PEM scenario, but with the explicit override — this" \
        "must be the only way to proceed, and must actually generate and compile in a new key" \
        "since there is no existing private key to derive one from."

    local key_a="$fixture/keypem/key-a.pem"
    local missing_key="$fixture/keypem/does-not-exist.pem"
    local data_file="$fixture/keys/release-public-key.base64"

    FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" >/dev/null 2>&1
    local key_a_public
    key_a_public="$(read_data_file "$data_file")"

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$missing_key" "$fixture/scripts/make-release-signing-key.sh" --rotate-established-key 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "--rotate-established-key did not proceed for a missing PEM; got:"$'\n'"$output"
        return
    fi
    if [[ ! -f "$missing_key" ]]; then
        fail "--rotate-established-key did not generate a new private key at $missing_key"
        return
    fi
    local perms
    perms="$(stat -f '%Lp' "$missing_key")"
    if [[ "$perms" != "600" ]]; then
        fail "newly generated private key mode is $perms, expected 600"
        return
    fi
    local derived established
    derived="$(derive_public_key_base64 "$missing_key")"
    established="$(read_data_file "$data_file")"
    if [[ -z "$derived" || "$derived" != "$established" ]]; then
        fail "after --rotate-established-key, established public key ('$established') doesn't match the" \
            "newly generated key's ('$derived')"
        return
    fi
    if [[ "$established" == "$key_a_public" ]]; then
        fail "established public key is still key A's — no rotation actually happened"
        return
    fi
    pass "--rotate-established-key generated a fresh key and rotated the anchor when the" \
        "configured PEM path didn't exist"
}

test_empty_data_file_is_rejected_not_treated_as_absent() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-6/7 Finding 2 direction: keys/release-public-key.base64 existing but EMPTY must" \
        "be treated as MALFORMED — not silently treated as 'nothing established yet', which" \
        "would let a brand-new key be generated without --rotate-established-key even though a" \
        "real anchor may already be deployed."

    local key_path="$fixture/keypem/release-signing-key.pem"
    local data_file="$fixture/keys/release-public-key.base64"

    # An empty (but existing) data file — e.g. a partial checkout, a botched merge, or manual
    # corruption. No PEM at $key_path either, the same way a fresh publisher workstation or a
    # lost key looks; a script that conflated "empty" with "absent" would go on to generate a
    # brand-new key here.
    : >"$data_file"

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_path" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "the script exited 0 (either generated a key or reported nothing to do) despite" \
            "\$data_file being empty — it must fail closed instead"
        echo "$output"
        return
    fi
    if [[ -f "$key_path" ]]; then
        fail "the script generated a NEW private key at $key_path despite the established-key" \
            "source being unreadable — it must never guess based on a file it couldn't parse"
        return
    fi
    if [[ "$output" == *"ESTABLISHED public key"* ]]; then
        fail "the script treated the empty file as an ESTABLISHED-anchor mismatch rather than" \
            "reporting it as malformed/unreadable; got:"$'\n'"$output"
        return
    fi
    pass "empty keys/release-public-key.base64 rejected as malformed; no key generated"
}

test_multi_line_data_file_is_rejected_not_treated_as_absent() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-7 Finding 1 direction: keys/release-public-key.base64 holding a SECOND value" \
        "(a decoy line) — the exact shape that, when the trust anchor lived inside hand-written" \
        "Swift source, let a naive extractor silently prefer the wrong one — must be rejected" \
        "outright as MALFORMED. This file format has no syntax for a second declaration, an" \
        "inactive #if, or a comment to hide one inside: any extra content is just a second line," \
        "which is unambiguously invalid, not silently resolved one way or the other."

    local key_path="$fixture/keypem/release-signing-key.pem"
    local data_file="$fixture/keys/release-public-key.base64"

    local key_a key_b
    key_a="$(openssl genpkey -algorithm ED25519 2>/dev/null | openssl pkey -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)"
    key_b="$(openssl genpkey -algorithm ED25519 2>/dev/null | openssl pkey -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)"
    printf '%s\n%s\n' "$key_a" "$key_b" >"$data_file"

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_path" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "the script exited 0 despite \$data_file holding two candidate values — it must" \
            "refuse to guess which one is real, not silently pick either"
        echo "$output"
        return
    fi
    if [[ -f "$key_path" ]]; then
        fail "the script generated a NEW private key despite the established-key source holding" \
            "an ambiguous (two-value) file"
        return
    fi
    if [[ "$(cat "$data_file")" != "$key_a"$'\n'"$key_b" ]]; then
        fail "the script modified the ambiguous data file instead of leaving it untouched for" \
            "the operator to fix or restore from git"
        return
    fi
    pass "two-value (decoy) keys/release-public-key.base64 rejected as malformed; no key" \
        "generated, file left untouched"
}

test_fresh_generation_produces_a_matching_pair
test_interrupted_run_resumes_without_regenerating_the_key
test_established_anchor_mismatch_is_refused_without_override
test_missing_pem_with_established_anchor_is_refused_without_override
test_missing_pem_with_established_anchor_rotates_with_explicit_override
test_established_anchor_mismatch_rotates_with_explicit_override
test_empty_data_file_is_rejected_not_treated_as_absent
test_multi_line_data_file_is_rejected_not_treated_as_absent

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All make-release-signing-key tests passed."
    exit 0
else
    echo "$FAILURES make-release-signing-key test(s) failed." >&2
    exit 1
fi
