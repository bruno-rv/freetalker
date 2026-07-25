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
    mkdir -p "$fixture/scripts/lib" "$fixture/Sources/FreeTalker/Update" "$fixture/keys"
    cp "$REPO_ROOT/scripts/make-release-signing-key.sh" "$fixture/scripts/make-release-signing-key.sh"
    chmod +x "$fixture/scripts/make-release-signing-key.sh"
    # make-release-signing-key.sh sources this relative to its OWN location (REPO_ROOT), so the
    # fixture needs its own copy too — the REAL file, never a re-derived stand-in.
    cp "$REPO_ROOT/scripts/lib/public-key-extract.sh" "$fixture/scripts/lib/public-key-extract.sh"
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

test_established_anchor_mismatch_is_refused_without_override() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-4 Finding 3: an ESTABLISHED public key (already trusted by real, already-built"
    log "installs) must NOT be silently overwritten just because a DIFFERENT valid key happens"
    log "to be at \$FREETALKER_RELEASE_SIGNING_KEY — the exact accident the finding describes"
    log "(env var pointing at the wrong file), reproduced with the REAL script establishing the"
    log "anchor first, not a hand-written fixture Swift file."

    local key_a="$fixture/keys/key-a.pem"
    local key_b="$fixture/keys/key-b.pem"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"

    # Establish key A as the anchor the same way a real first-time setup would: let the REAL
    # script generate it and write UpdatePublicKey.swift for it.
    FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" >/dev/null 2>&1
    local established_swift_content
    established_swift_content="$(cat "$swift_path")"

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
    if [[ "$(cat "$swift_path")" != "$established_swift_content" ]]; then
        fail "UpdatePublicKey.swift (the established anchor, key A) was modified despite being refused"
        return
    fi
    if [[ "$(cat "$key_b")" != "$key_b_content_before" ]]; then
        fail "key B's PEM was modified — this script must never touch a key file it refuses to use"
        return
    fi
    pass "established anchor mismatch refused without --rotate-established-key; UpdatePublicKey.swift (key A) untouched"
}

test_established_anchor_mismatch_rotates_with_explicit_override() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-4 Finding 3: the SAME established-mismatch scenario, but with the explicit," \
        "clearly-named override — this must be the only way to proceed, and must actually work"

    local key_a="$fixture/keys/key-a.pem"
    local key_b="$fixture/keys/key-b.pem"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"

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
        fail "rotating regenerated key B's PRIVATE key — it must only ever rewrite UpdatePublicKey.swift"
        return
    fi
    local derived compiled
    derived="$(derive_public_key_base64 "$key_b")"
    compiled="$(extract_public_key_swift "$swift_path")"
    if [[ -z "$derived" || "$derived" != "$compiled" ]]; then
        fail "after --rotate-established-key, compiled public key ('$compiled') doesn't match key B's ('$derived')"
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

    local key_a="$fixture/keys/key-a.pem"
    local missing_key="$fixture/keys/does-not-exist.pem"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"

    # Establish key A as the anchor the same way a real first-time setup would.
    FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" >/dev/null 2>&1
    local established_swift_content
    established_swift_content="$(cat "$swift_path")"

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
    if [[ "$(cat "$swift_path")" != "$established_swift_content" ]]; then
        fail "UpdatePublicKey.swift (the established anchor, key A) was modified despite being refused"
        return
    fi
    pass "missing PEM with an established anchor refused without --rotate-established-key;" \
        "no new key generated, UpdatePublicKey.swift (key A) untouched"
}

test_missing_pem_with_established_anchor_rotates_with_explicit_override() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-5 Finding 1: the SAME missing-PEM scenario, but with the explicit override — this" \
        "must be the only way to proceed, and must actually generate and compile in a new key" \
        "since there is no existing private key to derive one from."

    local key_a="$fixture/keys/key-a.pem"
    local missing_key="$fixture/keys/does-not-exist.pem"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"

    FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" >/dev/null 2>&1
    local key_a_public
    key_a_public="$(extract_public_key_swift "$swift_path")"

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
    local derived compiled
    derived="$(derive_public_key_base64 "$missing_key")"
    compiled="$(extract_public_key_swift "$swift_path")"
    if [[ -z "$derived" || "$derived" != "$compiled" ]]; then
        fail "after --rotate-established-key, compiled public key ('$compiled') doesn't match the" \
            "newly generated key's ('$derived')"
        return
    fi
    if [[ "$compiled" == "$key_a_public" ]]; then
        fail "compiled public key is still key A's — no rotation actually happened"
        return
    fi
    pass "--rotate-established-key generated a fresh key and rotated the anchor when the" \
        "configured PEM path didn't exist"
}

test_malformed_swift_truncated_before_complete_assignment_is_rejected_not_treated_as_absent() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-6 Finding 2 (direction 1): UpdatePublicKey.swift truncated BEFORE a closed" \
        "'base64 = \"...\"' assignment must be treated as MALFORMED — not silently treated as" \
        "'nothing established yet', which would let a brand-new key be generated without" \
        "--rotate-established-key even though a real anchor may already be deployed."

    local key_path="$fixture/keys/release-signing-key.pem"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"

    # Simulates corruption of an established anchor: a Swift file that cuts off mid-assignment,
    # never reaching a closing quote — the exact shape the finding describes. No PEM at
    # $key_path either, the same way a fresh publisher workstation or a lost key looks; the OLD
    # buggy script treated "extraction returned empty" here as "nothing established yet" and
    # would go on to generate a brand-new key.
    cat >"$swift_path" <<'EOF'
import CryptoKit
import Foundation

enum UpdatePublicKey {
    static let base64 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
EOF

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_path" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "the script exited 0 (either generated a key or reported nothing to do) despite" \
            "\$swift_path being truncated mid-assignment — it must fail closed instead"
        echo "$output"
        return
    fi
    if [[ -f "$key_path" ]]; then
        fail "the script generated a NEW private key at $key_path despite the compiled-in" \
            "source being unparseable — it must never guess based on source it couldn't parse"
        return
    fi
    if [[ "$output" == *"ESTABLISHED public key"* ]]; then
        fail "the script treated the truncated file as an ESTABLISHED-anchor mismatch rather" \
            "than reporting it as malformed/unparseable; got:"$'\n'"$output"
        return
    fi
    pass "truncated-before-close Swift source rejected as malformed; no key generated"
}

test_malformed_swift_truncated_after_complete_assignment_is_rejected_not_nothing_to_do() {
    local fixture
    fixture="$(make_fixture)"
    trap 'rm -rf "$fixture"' RETURN

    log "Round-6 Finding 2 (direction 2): UpdatePublicKey.swift truncated immediately AFTER an" \
        "otherwise complete, well-formed 'base64 = \"...\"' assignment line must still be" \
        "treated as MALFORMED — not reported as a true no-op 'Nothing to do', which would leave" \
        "an invalid Swift file in place with no warning at all."

    local key_a="$fixture/keys/key-a.pem"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"

    # Establish a real anchor with the REAL script first, exactly like a real first-time setup.
    FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" >/dev/null 2>&1
    local key_a_public
    key_a_public="$(derive_public_key_base64 "$key_a")"

    # Truncate right after the assignment line — the line itself stays perfectly well-formed and
    # matches key A exactly, but the rest of the enum body (and its closing brace) is gone. The
    # OLD buggy script only ever looked at this one line, so it would report "Nothing to do" —
    # true of the KEY, false of the FILE, which won't even compile.
    local expected_truncated_content
    expected_truncated_content="$(cat <<EOF
import CryptoKit
import Foundation

enum UpdatePublicKey {
    static let base64 = "$key_a_public"
EOF
)"
    printf '%s\n' "$expected_truncated_content" >"$swift_path"

    local output status
    set +e
    output="$(FREETALKER_RELEASE_SIGNING_KEY="$key_a" "$fixture/scripts/make-release-signing-key.sh" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "the script exited 0 despite \$swift_path being truncated right after an otherwise" \
            "complete assignment line — it must not treat this as 'nothing to do'"
        echo "$output"
        return
    fi
    if [[ "$output" == *"Nothing to do"* ]]; then
        fail "the script reported 'Nothing to do' over a truncated/invalid Swift file — exactly" \
            "the bug Finding 2 describes: a broken file left in place with no warning"
        return
    fi
    local swift_content_after
    swift_content_after="$(cat "$swift_path")"
    if [[ "$swift_content_after" != "$expected_truncated_content" ]]; then
        fail "the script modified the truncated/malformed Swift file instead of leaving it" \
            "untouched for the operator to fix or restore from git"
        return
    fi
    if [[ "$(cat "$key_a")" == "" ]]; then
        fail "test setup bug: key A's PEM is empty"
        return
    fi
    pass "truncated-after-close Swift source rejected as malformed, not reported as 'Nothing to do'"
}

test_fresh_generation_produces_a_matching_pair
test_interrupted_run_resumes_without_regenerating_the_key
test_established_anchor_mismatch_is_refused_without_override
test_missing_pem_with_established_anchor_is_refused_without_override
test_missing_pem_with_established_anchor_rotates_with_explicit_override
test_established_anchor_mismatch_rotates_with_explicit_override
test_malformed_swift_truncated_before_complete_assignment_is_rejected_not_treated_as_absent
test_malformed_swift_truncated_after_complete_assignment_is_rejected_not_nothing_to_do

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All make-release-signing-key tests passed."
    exit 0
else
    echo "$FAILURES make-release-signing-key test(s) failed." >&2
    exit 1
fi
