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

    # The REAL Makefile, byte-for-byte — never a re-derived stand-in — `include`d so this
    # fixture's `codesign-identity-check` target (and the `export CODESIGN_IDENTITY` /
    # `CODESIGN_IDENTITY_ALLOWLIST_PATTERN` it depends on) is production's actual logic, not a
    # hand-copied approximation of it. This is what closes Round-4 Finding 1's harness gap: the
    # OLD fake `bundle` target here never called `codesign` at all, so a hostile
    # `.codesign-identity` couldn't be caught by this suite regardless of what the real Makefile
    # did or didn't validate. `build` and `bundle` are then redefined below — GNU Make accumulates
    # prerequisites across every rule for the same target and uses the recipe from whichever rule
    # provides one, so `bundle`'s real prerequisite on `codesign-identity-check` (see Makefile)
    # is preserved while its expensive `swift build`/codesign steps are replaced by this fixture's
    # fast fake ones.
    cp "$REPO_ROOT/Makefile" "$fixture/RealMakefile.mk"
    cat >"$fixture/Makefile" <<'MAKEFILE'
APP_NAME := FreeTalker
include RealMakefile.mk

.PHONY: build bundle
build:
	@true

bundle:
	sleep 0.5
	rm -rf $(APP_NAME).app
	mkdir -p $(APP_NAME).app/Contents/MacOS
	git rev-parse HEAD > $(APP_NAME).app/Contents/MacOS/built-from-commit.txt
	/usr/bin/plutil -create xml1 $(APP_NAME).app/Contents/Info.plist
	@if [ -n "$$VERSION_OVERRIDE" ]; then ver="$$VERSION_OVERRIDE"; else ver="0.0.0"; fi; \
	/usr/bin/plutil -insert CFBundleShortVersionString -string "$$ver" $(APP_NAME).app/Contents/Info.plist
MAKEFILE

    # Untracked, exactly like the real repo's `.codesign-identity` (confirmed: `git ls-files
    # .codesign-identity` in the real checkout returns nothing) — so a test that overwrites it
    # in-place (see the hostile-identity test below) never trips release.sh's own
    # `git status --porcelain` cleanliness check for an unrelated reason.
    echo ".codesign-identity" >"$fixture/.gitignore"
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

test_signature_is_rejected_if_the_signing_key_file_is_swapped_mid_build() {
    local fixture commit_a commit_b
    { read -r fixture; read -r commit_a; read -r commit_b; } < <(make_fixture)
    : "$commit_b" # unused in this test
    trap 'rm -rf "$fixture"' RETURN

    log "Round-4 Finding 2 (sequence a): the release-signing key file is atomically replaced with"
    log "a DIFFERENT (but validly Ed25519) key while 'make bundle' is running. The pre-build check"
    log "(Round-3 Finding 3) validated the ORIGINAL key against the live tree before the build"
    log "started; only a check AFTER signing — against BUILD_COMMIT's own compiled-in public key,"
    log "not the live tree — can catch the actual bytes that ended up signing the artifact."
    local other_key
    other_key="$(mktemp -d)/other-key.pem"
    openssl genpkey -algorithm ED25519 -out "$other_key" 2>/dev/null

    # Swaps the file at $fixture/release-signing-key.pem — the SAME path release.sh reads both
    # before the build (pre-build validation) and after it (the actual `openssl pkeyutl -sign`
    # call) — mid-build, atomically (write-to-temp-then-rename, same discipline
    # scripts/make-release-signing-key.sh itself uses for the real key file). Timed against the
    # fake bundle recipe's 0.5s sleep, the same synchronization point the concurrent-checkout test
    # above uses, generously margined the same way.
    (
        sleep 0.3
        cp "$other_key" "$fixture/release-signing-key.pem.swap-tmp"
        mv "$fixture/release-signing-key.pem.swap-tmp" "$fixture/release-signing-key.pem"
    ) &
    local racer_pid=$!

    local output status
    set +e
    output="$(cd "$fixture" && FREETALKER_RELEASE_SIGNING_KEY="$fixture/release-signing-key.pem" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
    status=$?
    set -e
    wait "$racer_pid"

    if [[ "$status" -eq 0 ]]; then
        fail "release.sh --dry-run succeeded despite the signing key being swapped mid-build"
        echo "$output"
        return
    fi
    if [[ "$output" == *"does NOT match the public key compiled"* ]]; then
        # The racer landed before pre-build validation even finished reading the ORIGINAL key —
        # still a safe outcome, but not evidence of the NEW post-sign check working. Report
        # inconclusive rather than a false pass or fail; a rerun should land the intended window.
        fail "the racer swapped the key before pre-build validation ran (caught by the EXISTING" \
            "Round-3 check, not the new post-sign one) — inconclusive for this test; rerun"
        return
    fi
    if [[ "$output" != *"does NOT verify against BUILD_COMMIT's own"* ]]; then
        fail "release.sh failed for an unexpected reason (expected the post-sign verification" \
            "to reject the mismatched signature); got:"$'\n'"$output"
        return
    fi
    if [[ -e "$fixture/dist" ]]; then
        fail "release.sh left dist/ behind despite the post-sign verification rejecting the artifact"
        return
    fi
    pass "a signature produced with a key swapped in mid-build was caught by post-sign verification, and dist/ was cleaned up"
}

test_hostile_codesign_identity_is_rejected_end_to_end() {
    local fixture commit_a commit_b
    { read -r fixture; read -r commit_a; read -r commit_b; } < <(make_fixture)
    : "$commit_a" "$commit_b" # unused in this test
    trap 'rm -rf "$fixture"' RETURN

    log "Round-4 Finding 1: a hostile .codesign-identity must be rejected before any signing,"
    log "reproduced through the exact path release.sh takes (make bundle) — the REAL Makefile's"
    log "codesign-identity-check target, not a re-derived stand-in (see make_fixture's 'include')"

    # The EXACT payload from the finding: a command-injection primitive that, against the OLD
    # Makefile (`codesign --force --deep -s "$(CODESIGN_IDENTITY)" ...` — Make-substituted
    # textually, not read as a shell variable), broke out of the quoting and ran as arbitrary
    # shell, with the injected `chmod`'s success masking the injected/broken `codesign` call's
    # failure.
    printf '%s' 'x"; cp /tmp/payload FreeTalker.app/Contents/MacOS/FreeTalker; chmod +x FreeTalker.app/Contents/MacOS/FreeTalker; #' \
        >"$fixture/.codesign-identity"

    local output status
    set +e
    output="$(cd "$fixture" && FREETALKER_RELEASE_SIGNING_KEY="$fixture/release-signing-key.pem" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        fail "release.sh --dry-run accepted a hostile .codesign-identity"
        echo "$output"
        return
    fi
    if [[ "$output" != *"CODESIGN_IDENTITY failed strict validation"* ]]; then
        fail "release.sh rejected the hostile identity but not via the expected Makefile" \
            "validation message; got:"$'\n'"$output"
        return
    fi
    if [[ -e "$fixture/dist" ]]; then
        fail "release.sh created dist/ despite the hostile identity being rejected"
        return
    fi
    pass "hostile .codesign-identity rejected end-to-end via release.sh -> make bundle, before any build or signing work"

    log "Round-4 Finding 1: a legitimate identity (containing real codesign-identity characters" \
        "like a colon and parentheses) must still be accepted"
    printf '%s' 'Developer ID Application: Someone (ABCDE12345)' >"$fixture/.codesign-identity"
    set +e
    output="$(cd "$fixture" && FREETALKER_RELEASE_SIGNING_KEY="$fixture/release-signing-key.pem" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        fail "release.sh --dry-run rejected a legitimate codesign identity; got:"$'\n'"$output"
        return
    fi
    if [[ ! -f "$fixture/dist/FreeTalker-v0.0.1.app.zip" ]]; then
        fail "release.sh accepted the legitimate identity but did not produce the expected asset;" \
            "output:"$'\n'"$output"
        return
    fi
    pass "legitimate codesign identity still accepted, dry run produced dist/FreeTalker-v0.0.1.app.zip"
}

test_missing_build_commit_key_source_aborts_and_cleans_dist() {
    local fixture commit_a commit_b
    { read -r fixture; read -r commit_a; read -r commit_b; } < <(make_fixture)
    : "$commit_b" # unused in this test
    trap 'rm -rf "$fixture"' RETURN

    log "Round-5 Finding 2: BUILD_COMMIT's own compiled-in public key source going missing (e.g. an"
    log "old commit that predates UpdatePublicKey.swift entirely, reached mid-flight the same way" \
        "Round-4 Finding 4's concurrent-checkout race reaches BUILD_COMMIT) must abort AND clean up" \
        "dist/, not let a bare 'sed ...' assignment under 'set -e' kill the script before the" \
        "existing cleanup path (the -z check right after it) ever runs."

    # Reproduces the missing-source state inside release.sh's OWN isolated worktree — never this
    # fixture's live tree, which must keep a valid, matching UpdatePublicKey.swift throughout so
    # the pre-build key-match check (Round-3 Finding 3) still passes — by deleting the file from
    # the worktree the instant it appears, well before the fake bundle recipe's own 0.5s sleep
    # completes, let alone the zip/checksum/sign/post-verify steps that follow it. The glob matches
    # only release.sh's own `mktemp -d ".../freetalker-release-XXXXXX"` worktree, never this
    # fixture's root (`freetalker-release-test-XXXXXX`) — six wildcard characters then end of
    # pattern excludes the longer "-test-XXXXXX" suffix.
    (
        for _ in $(seq 1 200); do
            for candidate in "${TMPDIR:-/tmp}"/freetalker-release-??????; do
                [[ -d "$candidate" ]] || continue
                target="$candidate/Sources/FreeTalker/Update/UpdatePublicKey.swift"
                if [[ -f "$target" ]]; then
                    rm -f "$target"
                    exit 0
                fi
            done
            sleep 0.01
        done
    ) &
    local racer_pid=$!

    local output status
    set +e
    output="$(cd "$fixture" && FREETALKER_RELEASE_SIGNING_KEY="$fixture/release-signing-key.pem" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
    status=$?
    set -e
    wait "$racer_pid"

    if [[ "$status" -eq 0 ]]; then
        fail "release.sh --dry-run succeeded despite BUILD_COMMIT's own public-key source going missing"
        echo "$output"
        return
    fi
    if [[ "$output" != *"could not read the compiled-in public key from BUILD_COMMIT's own source"* ]]; then
        fail "release.sh failed for an unexpected reason (expected the missing-source message);" \
            "got:"$'\n'"$output"
        return
    fi
    if [[ -e "$fixture/dist" ]]; then
        fail "release.sh left dist/ behind despite BUILD_COMMIT's own public-key source going" \
            "missing — this is exactly Finding 2: a bare 'sed ...' assignment under set -e must not" \
            "exit before the existing cleanup path runs"
        return
    fi
    pass "missing BUILD_COMMIT public-key source aborted with the expected message, and dist/ was cleaned up"
}

test_key_mismatch_rejected_and_matching_key_accepted
test_artifact_is_immune_to_a_concurrent_checkout_away_and_back
test_signature_is_rejected_if_the_signing_key_file_is_swapped_mid_build
test_hostile_codesign_identity_is_rejected_end_to_end
test_missing_build_commit_key_source_aborts_and_cleans_dist

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All release script tests passed."
    exit 0
else
    echo "$FAILURES release script test(s) failed." >&2
    exit 1
fi
