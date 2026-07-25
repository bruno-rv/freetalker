#!/bin/bash
# scripts/test-release-script.sh — regression tests for scripts/release.sh that don't need a
# full FreeTalker build.
#
# Runs the REAL, unmodified scripts/release.sh (copied byte-for-byte into an isolated fixture
# git repo, never the real freetalker-install checkout) against a minimal fake `make bundle`
# target, so these exercise release.sh's actual logic rather than a re-derived stand-in. Two
# scenarios, both regressions closed in this round:
#
#   1. Round-3 Finding 3 — a release-signing key whose PUBLIC half doesn't match the compiled-in
#      UpdatePublicKey.swift must be rejected before any build work; the matching key must be
#      accepted.
#   2. Round-3 Finding 4 — the published artifact must come from a PRISTINE checkout of
#      BUILD_COMMIT, immune to a concurrent `git checkout` to a different commit and back in the
#      live working tree during the build.
#
# Never touches /Applications, never generates or pushes a real git tag, never calls `gh` (both
# invocations below use --dry-run only, as required).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

log() { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $*"; }

# Builds a throwaway fixture git repo at $1 with:
#   - a minimal Makefile whose `bundle` target stamps CFBundleShortVersionString from
#     VERSION_OVERRIDE and records the CURRENT git commit (of wherever `make bundle` is actually
#     invoked from) into the bundle — the property release.sh's own worktree isolation depends
#     on to be testable at all.
#   - a copy of the REAL scripts/release.sh (never a rewritten stand-in).
#   - a fixture Sources/FreeTalker/Update/UpdatePublicKey.swift and a matching (or, for the
#     mismatch test, deliberately non-matching) Ed25519 private key.
#   - a non-"-" .codesign-identity (release.sh only checks this string; the fake `bundle` target
#     never actually invokes `codesign`, so this doesn't need to be a real Keychain identity).
# Prints two lines on stdout: the fixture root, then commit A's hash, then commit B's hash.
make_fixture() {
    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-release-test-XXXXXX")"

    git -C "$fixture" init --quiet
    git -C "$fixture" config user.email "test@example.com"
    git -C "$fixture" config user.name "Release Script Test"

    mkdir -p "$fixture/scripts" "$fixture/Sources/FreeTalker/Update"
    cp "$REPO_ROOT/scripts/release.sh" "$fixture/scripts/release.sh"
    chmod +x "$fixture/scripts/release.sh"

    cat >"$fixture/Makefile" <<'MAKEFILE'
APP_NAME := FreeTalker

.PHONY: bundle
bundle:
	sleep 0.5
	rm -rf $(APP_NAME).app
	mkdir -p $(APP_NAME).app/Contents/MacOS
	git rev-parse HEAD > $(APP_NAME).app/Contents/MacOS/built-from-commit.txt
	/usr/bin/plutil -create xml1 $(APP_NAME).app/Contents/Info.plist
	@if [ -n "$$VERSION_OVERRIDE" ]; then ver="$$VERSION_OVERRIDE"; else ver="0.0.0"; fi; \
	/usr/bin/plutil -insert CFBundleShortVersionString -string "$$ver" $(APP_NAME).app/Contents/Info.plist
MAKEFILE

    echo "Fixture Test Identity" >"$fixture/.codesign-identity"

    openssl genpkey -algorithm ED25519 -out "$fixture/release-signing-key.pem" 2>/dev/null
    local pubkey_base64
    pubkey_base64="$(
        openssl pkey -in "$fixture/release-signing-key.pem" -pubout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | tail -c 32 | openssl base64 -A
    )"
    cat >"$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift" <<EOF
enum UpdatePublicKey {
    static let base64 = "$pubkey_base64"
}
EOF

    git -C "$fixture" add -A
    git -C "$fixture" commit --quiet -m "commit A"
    local commit_a
    commit_a="$(git -C "$fixture" rev-parse HEAD)"

    echo "changed on commit B" >"$fixture/UNRELATED_FILE.txt"
    git -C "$fixture" add -A
    git -C "$fixture" commit --quiet -m "commit B"
    local commit_b
    commit_b="$(git -C "$fixture" rev-parse HEAD)"

    git -C "$fixture" checkout --quiet "$commit_a"

    echo "$fixture"
    echo "$commit_a"
    echo "$commit_b"
}

test_key_mismatch_rejected_and_matching_key_accepted() {
    local fixture commit_a commit_b
    { read -r fixture; read -r commit_a; read -r commit_b; } < <(make_fixture)
    : "$commit_b" # unused in this test
    trap 'rm -rf "$fixture"' RETURN

    log "Finding 3: a mismatched signing key must be rejected before any build work"
    local other_key
    other_key="$(mktemp -d)/other-key.pem"
    openssl genpkey -algorithm ED25519 -out "$other_key" 2>/dev/null

    local output status
    set +e
    output="$(cd "$fixture" && FREETALKER_RELEASE_SIGNING_KEY="$other_key" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "release.sh --dry-run accepted a signing key that does NOT match the compiled-in public key"
        echo "$output"
        return
    fi
    if [[ "$output" != *"does NOT match the public key"* ]]; then
        fail "release.sh rejected the mismatched key but not with the expected message; got:"$'\n'"$output"
        return
    fi
    if [[ -e "$fixture/dist" ]]; then
        fail "release.sh created dist/ despite rejecting the key before any build work"
        return
    fi
    pass "mismatched key rejected before any build work, with a clear error"

    log "Finding 3: the ACTUAL matching key must be accepted"
    set +e
    output="$(cd "$fixture" && FREETALKER_RELEASE_SIGNING_KEY="$fixture/release-signing-key.pem" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "release.sh --dry-run rejected the CORRECT matching key; got:"$'\n'"$output"
        return
    fi
    if [[ ! -f "$fixture/dist/FreeTalker-v0.0.1.app.zip" ]]; then
        fail "release.sh accepted the matching key but did not produce the expected asset; output:"$'\n'"$output"
        return
    fi
    pass "matching key accepted, dry run produced dist/FreeTalker-v0.0.1.app.zip"
}

test_artifact_is_immune_to_a_concurrent_checkout_away_and_back() {
    local fixture commit_a commit_b
    { read -r fixture; read -r commit_a; read -r commit_b; } < <(make_fixture)
    trap 'rm -rf "$fixture"' RETURN

    log "Finding 4: a concurrent checkout to $commit_b and back to $commit_a during the build"
    log "must NOT be able to influence the published artifact"

    # Reproduces the finding's exact shape in THIS fixture's live tree (never the real repo):
    # while release.sh is running (specifically, while its isolated worktree's `make bundle` is
    # in its own 0.5s sleep before capturing HEAD), a concurrent actor checks the SAME working
    # tree release.sh was invoked from out to a different clean commit and back. Generously
    # margined so the racer's B-window reliably overlaps the build step regardless of release.sh's
    # own pre-build work (git status/key checks) taking a little longer on a loaded machine.
    (
        sleep 0.3
        git -C "$fixture" checkout --quiet "$commit_b"
        sleep 1.2
        git -C "$fixture" checkout --quiet "$commit_a"
    ) &
    local racer_pid=$!

    local output status
    set +e
    output="$(cd "$fixture" && FREETALKER_RELEASE_SIGNING_KEY="$fixture/release-signing-key.pem" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
    status=$?
    set -e
    wait "$racer_pid"

    if [[ "$status" -ne 0 ]]; then
        fail "release.sh --dry-run failed unexpectedly during the concurrent-checkout scenario:"$'\n'"$output"
        return
    fi

    local asset_zip="$fixture/dist/FreeTalker-v0.0.1.app.zip"
    if [[ ! -f "$asset_zip" ]]; then
        fail "release.sh did not produce the expected asset; output:"$'\n'"$output"
        return
    fi

    local extract_dir
    extract_dir="$(mktemp -d)"
    ditto -x -k "$asset_zip" "$extract_dir" >/dev/null
    local built_from
    built_from="$(cat "$extract_dir/FreeTalker.app/Contents/MacOS/built-from-commit.txt")"
    rm -rf "$extract_dir"

    if [[ "$built_from" != "$commit_a" ]]; then
        fail "published artifact was built from $built_from, expected BUILD_COMMIT $commit_a" \
            "(commit B was $commit_b) — the live tree's concurrent checkout influenced the artifact"
        return
    fi
    pass "published artifact was built from BUILD_COMMIT ($commit_a) regardless of the concurrent checkout"
}

test_key_mismatch_rejected_and_matching_key_accepted
test_artifact_is_immune_to_a_concurrent_checkout_away_and_back

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All release script tests passed."
    exit 0
else
    echo "$FAILURES release script test(s) failed." >&2
    exit 1
fi
