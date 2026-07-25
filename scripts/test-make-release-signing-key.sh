#!/bin/bash
# scripts/test-make-release-signing-key.sh — regression tests for the resumability fix in
# scripts/make-release-signing-key.sh (Round-3 Finding 3's other half).
#
# Runs the REAL, unmodified scripts/make-release-signing-key.sh (copied byte-for-byte into an
# isolated fixture, never touching ~/.freetalker or the real repo's UpdatePublicKey.swift)
# against fixture paths supplied via its own environment-variable overrides
# (FREETALKER_RELEASE_SIGNING_KEY, FREETALKER_RELEASE_SIGNING_KEY_DIR) — the exact same
# mechanism scripts/release.sh uses, and the exact same script file, not a re-derived stand-in.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $*"; }

extract_public_key_swift() {
    sed -n 's/.*base64 = "\([^"]*\)".*/\1/p' "$1"
}

derive_public_key_base64() {
    openssl pkey -in "$1" -pubout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | tail -c 32 | openssl base64 -A
}

make_fixture() {
    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-keygen-test-XXXXXX")"
    mkdir -p "$fixture/scripts" "$fixture/Sources/FreeTalker/Update" "$fixture/keys"
    cp "$REPO_ROOT/scripts/make-release-signing-key.sh" "$fixture/scripts/make-release-signing-key.sh"
    chmod +x "$fixture/scripts/make-release-signing-key.sh"
    echo "$fixture"
}

test_fresh_generation_produces_a_matching_pair() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Fresh run: no PEM, no compiled public key yet"
    local key_path="$fixture/keys/release-signing-key.pem"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"
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
    local derived compiled
    derived="$(derive_public_key_base64 "$key_path")"
    compiled="$(extract_public_key_swift "$swift_path")"
    if [[ -z "$derived" || "$derived" != "$compiled" ]]; then
        fail "compiled public key ('$compiled') doesn't match the generated private key ('$derived')"
        return
    fi
    pass "fresh generation produced a matching private/public keypair, private key mode 600"
}

test_interrupted_run_resumes_without_regenerating_the_key() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Simulating Finding 3's exact interruption: PEM written, UpdatePublicKey.swift never updated"
    local key_path="$fixture/keys/release-signing-key.pem"
    openssl genpkey -algorithm ED25519 -out "$key_path" 2>/dev/null
    chmod 600 "$key_path"
    local key_before
    key_before="$(cat "$key_path")"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"
    # No UpdatePublicKey.swift at all yet — the OLD buggy script treated "PEM exists" alone as
    # "nothing to do" and exited 0 here, leaving this file missing/stale forever.

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_path" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "resuming an interrupted run failed unexpectedly:"$'\n'"$output"
        return
    fi
    if [[ ! -f "$swift_path" ]]; then
        fail "resumed run did not write $swift_path at all — this is exactly Finding 3's bug:" \
            "a rerun exits successfully merely because the PEM exists, without ever making the" \
            "compiled public key correspond to it"
        return
    fi
    local key_after
    key_after="$(cat "$key_path")"
    if [[ "$key_after" != "$key_before" ]]; then
        fail "resuming regenerated the PRIVATE key — it must only rewrite UpdatePublicKey.swift" \
            "from the EXISTING key, never replace the key itself"
        return
    fi
    local derived compiled
    derived="$(derive_public_key_base64 "$key_path")"
    compiled="$(extract_public_key_swift "$swift_path")"
    if [[ -z "$derived" || "$derived" != "$compiled" ]]; then
        fail "after resuming, compiled public key ('$compiled') still doesn't match the private key ('$derived')"
        return
    fi
    pass "resumed run wrote the missing UpdatePublicKey.swift to match the EXISTING key, without regenerating it"

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
    pass "re-running once PEM and compiled key already match is a true no-op"
}

test_fresh_generation_produces_a_matching_pair
test_interrupted_run_resumes_without_regenerating_the_key

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All make-release-signing-key tests passed."
    exit 0
else
    echo "$FAILURES make-release-signing-key test(s) failed." >&2
    exit 1
fi
