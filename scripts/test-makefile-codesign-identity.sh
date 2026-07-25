#!/bin/bash
# scripts/test-makefile-codesign-identity.sh — regression tests for the `codesign-identity-check`
# Make target (Round-4 Finding 1: `.codesign-identity` is a command-injection primitive that the
# release pipeline signs).
#
# Runs the REAL, unmodified Makefile (copied byte-for-byte into an isolated fixture, never a
# re-derived stand-in) via `make codesign-identity-check CODESIGN_IDENTITY=...` — no `swift
# build`/Xcode needed, since that target has no prerequisites, so this is fast enough to run on
# every change. scripts/test-release-script.sh separately exercises the SAME real target end-to-end
# through release.sh -> make bundle; this script exists to cheaply cover many more input variations
# than that heavier, slower path can afford to.
#
# Never touches /Applications, never builds anything, never calls codesign for real.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $*"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-makefile-identity-test-XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT
cp "$REPO_ROOT/Makefile" "$FIXTURE/Makefile"

# `make codesign-identity-check` in the fixture, with $1 as CODESIGN_IDENTITY. Prints combined
# stdout+stderr on stdout, returns make's exit status.
run_check() {
    (cd "$FIXTURE" && make codesign-identity-check CODESIGN_IDENTITY="$1") 2>&1
}

assert_rejected() {
    local identity="$1" label="$2"
    local output status
    set +e
    output="$(run_check "$identity")"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "$label: expected rejection, but codesign-identity-check accepted it"
        return
    fi
    if [[ "$output" != *"CODESIGN_IDENTITY failed strict validation"* && "$output" != *"CODESIGN_IDENTITY contains a newline"* ]]; then
        fail "$label: rejected, but not with an expected message; got:"$'\n'"$output"
        return
    fi
    pass "$label: rejected"
}

assert_accepted() {
    local identity="$1" label="$2"
    local output status
    set +e
    output="$(run_check "$identity")"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "$label: expected acceptance, but codesign-identity-check rejected it:"$'\n'"$output"
        return
    fi
    pass "$label: accepted"
}

log "The exact payload from the finding — command injection via chained shell commands"
assert_rejected \
    'x"; cp /tmp/payload FreeTalker.app/Contents/MacOS/FreeTalker; chmod +x FreeTalker.app/Contents/MacOS/FreeTalker; #' \
    "exact finding payload"

log "Other shell metacharacter injection shapes"
assert_rejected 'x$(rm -rf /)' "command substitution (dollar-paren)"
assert_rejected 'x`rm -rf /`' "command substitution (backtick)"
assert_rejected 'x && rm -rf /' "shell AND-chain"
assert_rejected 'x || rm -rf /' "shell OR-chain"
assert_rejected 'x | tee /tmp/pwned' "pipe"
assert_rejected 'x > /tmp/pwned' "redirect"
assert_rejected $'x\nrm -rf /' "embedded newline"
assert_rejected 'x\\; rm -rf /' "backslash-escape attempt"

log "A GNU Make \$(shell ...) call embedded in the value must never actually execute — this is a"
log "distinct vulnerability from shell-quoting injection: it happens inside MAKE'S OWN variable"
log "expansion (e.g. when 'export' computes the value for a recipe's environment), BEFORE any"
log "recipe — including the allowlist check itself — ever runs, so no shell-side validation can"
log "intercept it. Only a plain grep rejection is not proof of a fix here; the absence of the"
log "side effect is what matters."
MAKE_SHELL_POC_MARKER="$FIXTURE/make-shell-function-poc-marker"
rm -f "$MAKE_SHELL_POC_MARKER"
run_check "\$(shell touch $MAKE_SHELL_POC_MARKER)" >/dev/null 2>&1 || true
if [[ -e "$MAKE_SHELL_POC_MARKER" ]]; then
    fail "a \$(shell ...) call embedded in CODESIGN_IDENTITY actually executed (marker file was created) — Make's own variable expansion ran it regardless of the allowlist"
    rm -f "$MAKE_SHELL_POC_MARKER"
else
    pass "a \$(shell ...) call embedded in CODESIGN_IDENTITY never executed"
fi
assert_rejected '$(shell true)' "literal \$(shell ...) text is also rejected by the allowlist itself, as defense in depth"

log "The ad-hoc marker and real-world identity shapes must be accepted"
assert_accepted '-' "ad-hoc marker"
assert_accepted 'FreeTalker Dev' "plain stable identity name (this repo's own)"
assert_accepted 'Developer ID Application: Bruno Rodrigues Veloso (ABCDE12345)' "Apple Developer ID shape"
assert_accepted 'Apple Development: someone@example.com (ABCDE12345)' "Apple Development shape"
assert_accepted '0123456789ABCDEF0123456789ABCDEF01234567' "40-character SHA-1 fingerprint shape"

log "Empty identity must be rejected, not silently treated as ad-hoc"
assert_rejected '' "empty string"

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All Makefile codesign-identity tests passed."
    exit 0
else
    echo "$FAILURES Makefile codesign-identity test(s) failed." >&2
    exit 1
fi
