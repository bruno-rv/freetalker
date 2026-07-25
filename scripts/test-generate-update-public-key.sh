#!/bin/bash
# scripts/test-generate-update-public-key.sh — regression tests for
# scripts/generate-update-public-key.sh, the script the GenerateUpdatePublicKey SwiftPM build
# tool plugin (Plugins/GenerateUpdatePublicKey) runs on every `swift build`/`swift test` to turn
# keys/release-public-key.base64 into Sources/FreeTalker/Update/UpdatePublicKey.swift.
#
# Proves the two halves of "the compiled constant cannot drift from the data file, and the build
# must fail loudly rather than silently preferring one": (1) a missing or malformed data file
# fails the generator (and therefore the whole `swift build`) instead of writing a guessed or
# empty value, and (2) a well-formed data file always produces Swift source compiling in exactly
# that value.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$REPO_ROOT/scripts/generate-update-public-key.sh"
FAILURES=0

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $*"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-generate-pubkey-test-XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

VALID_KEY="0mX1eBHprb/TXBqWGAC9mpRmt9+pu/hCMdX2440U5Uk="

test_missing_data_file_fails_the_build_step() {
    local data_file="$FIXTURE/missing/release-public-key.base64"
    local output_file="$FIXTURE/missing-out/UpdatePublicKey.swift"
    mkdir -p "$(dirname "$output_file")"

    local output status
    set +e
    output="$("$GENERATOR" "$data_file" "$output_file" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "generator exited 0 despite a missing data file"
        echo "$output"
        return
    fi
    if [[ -f "$output_file" ]]; then
        fail "generator wrote $output_file despite failing — a stale/guessed file must never be left in place"
        return
    fi
    pass "missing data file fails the generator, no output file written"
}

test_malformed_data_file_fails_the_build_step_without_touching_a_stale_output() {
    local data_file="$FIXTURE/malformed/release-public-key.base64"
    local output_file="$FIXTURE/malformed-out/UpdatePublicKey.swift"
    mkdir -p "$(dirname "$data_file")" "$(dirname "$output_file")"
    printf 'not-valid-base64!!!\n' >"$data_file"
    printf 'stale content from a previous successful run\n' >"$output_file"

    local output status
    set +e
    output="$("$GENERATOR" "$data_file" "$output_file" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "generator exited 0 despite a malformed data file"
        echo "$output"
        return
    fi
    if [[ "$(cat "$output_file")" != "stale content from a previous successful run" ]]; then
        fail "generator modified $output_file on failure instead of leaving the previous" \
            "(stale but at least known-good) output untouched"
        return
    fi
    pass "malformed data file fails the generator, stale output file left untouched"
}

test_well_formed_data_file_generates_exactly_matching_swift() {
    local data_file="$FIXTURE/good/release-public-key.base64"
    local output_file="$FIXTURE/good-out/UpdatePublicKey.swift"
    mkdir -p "$(dirname "$data_file")" "$(dirname "$output_file")"
    printf '%s\n' "$VALID_KEY" >"$data_file"

    local output status
    set +e
    output="$("$GENERATOR" "$data_file" "$output_file" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "generator failed for a well-formed data file:"$'\n'"$output"
        return
    fi
    if [[ ! -f "$output_file" ]]; then
        fail "generator exited 0 but did not write $output_file"
        return
    fi
    if ! grep -qF "static let base64 = \"$VALID_KEY\"" "$output_file"; then
        fail "$output_file does not compile in the exact value from $data_file"
        cat "$output_file" >&2
        return
    fi
    if ! grep -qF "enum UpdatePublicKey {" "$output_file"; then
        fail "$output_file does not declare enum UpdatePublicKey"
        return
    fi
    pass "well-formed data file generates Swift source compiling in exactly that value"
}

test_missing_data_file_fails_the_build_step
test_malformed_data_file_fails_the_build_step_without_touching_a_stale_output
test_well_formed_data_file_generates_exactly_matching_swift

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All generate-update-public-key tests passed."
    exit 0
else
    echo "$FAILURES generate-update-public-key test(s) failed." >&2
    exit 1
fi
