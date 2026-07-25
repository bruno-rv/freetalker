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

# Scans "$1"/freetalker-release-?????? for a directory containing "$1_candidate/$2", deletes the
# FIRST one found, and returns 0; returns 1 if none was found this pass. Shared by the racer in
# test_missing_build_commit_key_source_aborts_and_cleans_dist (which loops this until BUILD_COMMIT's
# own worktree appears) and by test_racer_is_confined_to_its_own_root below (which calls it
# directly, once, to prove the SAME code that test relies on really is confined to whatever root
# it's given — round-6 finding 3).
racer_delete_target_under() {
    local search_root="$1" relative_target="$2"
    local candidate target
    for candidate in "$search_root"/freetalker-release-??????; do
        [[ -d "$candidate" ]] || continue
        target="$candidate/$relative_target"
        if [[ -f "$target" ]]; then
            rm -f "$target"
            return 0
        fi
    done
    return 1
}

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

    mkdir -p "$fixture/scripts/lib" "$fixture/Sources/FreeTalker/Update"
    cp "$REPO_ROOT/scripts/release.sh" "$fixture/scripts/release.sh"
    chmod +x "$fixture/scripts/release.sh"
    # release.sh sources this relative to its OWN location (REPO_ROOT), so the fixture needs its
    # own copy too — the REAL file, never a re-derived stand-in, so extraction logic here is
    # exactly what production uses (round-6 finding 1).
    cp "$REPO_ROOT/scripts/lib/public-key-extract.sh" "$fixture/scripts/lib/public-key-extract.sh"

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

    # Round-6 Finding 3 (REGRESSION): the racer below used to scan the GLOBAL
    # "${TMPDIR:-/tmp}/freetalker-release-??????" namespace and delete the FIRST match it found —
    # the exact same naming scheme a real, concurrently running `scripts/release.sh` (or another
    # invocation of this very harness) uses for its own isolated worktree. That let this test
    # destroy a worktree it did not create. Give the racer its OWN scoped root — created here,
    # torn down here, never touched by anything else — and point release.sh's OWN `mktemp -d
    # "${TMPDIR:-/tmp}/freetalker-release-XXXXXX"` at it via TMPDIR, so the racer's glob can only
    # ever match a worktree this exact test invocation created.
    local racer_root
    racer_root="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-release-test-racer-root-XXXXXX")"
    trap 'rm -rf "$fixture" "$racer_root" "$decoy_worktree"' RETURN

    # A decoy planted directly in the REAL ambient TMPDIR (never inside $racer_root), using the
    # exact "freetalker-release-XXXXXX" naming scheme and file layout a real concurrent
    # release.sh's own isolated worktree would have — standing in for that real worktree. Its
    # target file exists from the moment it's created (unlike the racer's actual intended
    # target, which only appears once release.sh's own `git worktree add` finishes), so an
    # unconfined racer would find and delete THIS on its very first pass, deterministically. A
    # properly confined racer (scanning only $racer_root) can never even enumerate it. This is
    # harmless either way — it's this test's own throwaway data, cleaned up above regardless of
    # outcome — but it directly proves the production racer call site stays confined; reverting
    # either the racer's glob root or the `TMPDIR=` override below makes this fail.
    local decoy_worktree decoy_target
    decoy_worktree="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-release-XXXXXX")"
    mkdir -p "$decoy_worktree/Sources/FreeTalker/Update"
    decoy_target="$decoy_worktree/Sources/FreeTalker/Update/UpdatePublicKey.swift"
    echo "decoy content — must never be touched by a properly confined racer" >"$decoy_target"

    log "Round-5 Finding 2: BUILD_COMMIT's own compiled-in public key source going missing (e.g. an"
    log "old commit that predates UpdatePublicKey.swift entirely, reached mid-flight the same way" \
        "Round-4 Finding 4's concurrent-checkout race reaches BUILD_COMMIT) must abort AND clean up" \
        "dist/, not let a bare 'sed ...' assignment under 'set -e' kill the script before the" \
        "existing cleanup path (the -z check right after it) ever runs."

    # Reproduces the missing-source state inside release.sh's OWN isolated worktree — never this
    # fixture's live tree, which must keep a valid, matching UpdatePublicKey.swift throughout so
    # the pre-build key-match check (Round-3 Finding 3) still passes — by deleting the file from
    # the worktree the instant it appears, well before the fake bundle recipe's own 0.5s sleep
    # completes, let alone the zip/checksum/sign/post-verify steps that follow it. The glob is
    # confined to $racer_root (see above), so even though it still matches release.sh's own
    # "freetalker-release-XXXXXX" naming scheme by design, it can never see (let alone delete)
    # anything outside the root this test alone created.
    (
        for _ in $(seq 1 200); do
            if racer_delete_target_under "$racer_root" "Sources/FreeTalker/Update/UpdatePublicKey.swift"; then
                exit 0
            fi
            sleep 0.01
        done
    ) &
    local racer_pid=$!

    local output status
    set +e
    output="$(cd "$fixture" && TMPDIR="$racer_root" FREETALKER_RELEASE_SIGNING_KEY="$fixture/release-signing-key.pem" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
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

    if [[ ! -f "$decoy_target" ]]; then
        fail "Round-6 Finding 3 (REGRESSION): the racer deleted the DECOY worktree's file instead" \
            "of (or in addition to) BUILD_COMMIT's own — it reached outside \$racer_root into the" \
            "real ambient TMPDIR namespace, exactly what a real concurrent release's isolated" \
            "worktree would sit in. Confinement is not actually working."
        return
    fi
    pass "the racer never touched the decoy worktree living in the real ambient TMPDIR" \
        "namespace outside \$racer_root — confinement holds"
}

test_ambiguous_public_key_declaration_is_rejected_not_silently_misextracted() {
    local fixture commit_a commit_b
    { read -r fixture; read -r commit_a; read -r commit_b; } < <(make_fixture)
    : "$commit_a" "$commit_b" # unused in this test
    trap 'rm -rf "$fixture"' RETURN

    log "Round-6 Finding 1: a UpdatePublicKey.swift line where a naive greedy sed extraction" \
        "disagrees with what Swift actually compiles must be rejected outright, never silently" \
        "signed against the wrong (attacker-controlled) value."

    # The exact shape from the finding. Swift compiles ONLY the first quoted literal (key A) —
    # everything after it, even text that itself looks like `base64 = "..."`, is just a trailing
    # comment with no effect on the compiled constant. A naive, unanchored, greedy
    # `sed 's/.*base64 = "\(...\)".*'` instead matches the LAST occurrence on the line and
    # silently returns key B. Generating a real PRIVATE key for B (not just a public value) is
    # what makes this a meaningful demonstration rather than an accidental pass: signing with
    # key_b_private is exactly what a naive extraction would let through as "matching," even
    # though every already-built client only trusts key A.
    local key_a key_b_private key_b
    key_a="$(openssl genpkey -algorithm ED25519 2>/dev/null | openssl pkey -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)"
    key_b_private="$(mktemp -d)/key-b.pem"
    openssl genpkey -algorithm ED25519 -out "$key_b_private" 2>/dev/null
    key_b="$(openssl pkey -in "$key_b_private" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | tail -c 32 | openssl base64 -A)"
    local swift_path="$fixture/Sources/FreeTalker/Update/UpdatePublicKey.swift"
    cat >"$swift_path" <<EOF
enum UpdatePublicKey {
    static let base64 = "$key_a" // base64 = "$key_b"
}
EOF
    git -C "$fixture" add -A
    git -C "$fixture" commit --quiet -m "ambiguous base64 declaration"

    # Sanity-check the fixture really reproduces the finding: the OLD naive sed must disagree
    # with what Swift compiles (key A) and return key B instead. If this ever stops being true
    # (e.g. the fixture's shape drifts), the test below would pass for the wrong reason.
    local naive_extraction
    naive_extraction="$(sed -n 's/.*base64 = "\([^"]*\)".*/\1/p' "$swift_path")"
    if [[ "$naive_extraction" != "$key_b" ]]; then
        fail "test setup invalid: expected the naive greedy sed to disagree with Swift and" \
            "extract key B ($key_b), got '$naive_extraction' — fixture doesn't reproduce Finding 1"
        return
    fi

    # Sign with key B's PRIVATE key — the one a naive extraction would treat as "matching" the
    # compiled-in value (it isn't; Swift compiles key A). A vulnerable release.sh happily accepts
    # this and produces dist/; the fix must reject the file outright, before ever looking at
    # which signing key was supplied.
    local output status
    set +e
    output="$(cd "$fixture" && FREETALKER_RELEASE_SIGNING_KEY="$key_b_private" ./scripts/release.sh v0.0.1 --dry-run 2>&1)"
    status=$?
    set -e
    rm -rf "$(dirname "$key_b_private")"
    if [[ "$status" -eq 0 ]]; then
        fail "release.sh --dry-run accepted an ambiguous base64 declaration and signed with key" \
            "B's private key ($key_b) instead of rejecting the file outright — Swift actually" \
            "compiles key A ($key_a), so every already-built client would reject this release"
        echo "$output"
        return
    fi
    if [[ -e "$fixture/dist" ]]; then
        fail "release.sh created dist/ despite the ambiguous base64 declaration"
        return
    fi
    pass "ambiguous base64 declaration (naive sed disagrees with what Swift compiles) rejected" \
        "before any build or signing work, instead of being silently misextracted"
}

test_key_mismatch_rejected_and_matching_key_accepted
test_artifact_is_immune_to_a_concurrent_checkout_away_and_back
test_signature_is_rejected_if_the_signing_key_file_is_swapped_mid_build
test_hostile_codesign_identity_is_rejected_end_to_end
test_missing_build_commit_key_source_aborts_and_cleans_dist
test_ambiguous_public_key_declaration_is_rejected_not_silently_misextracted

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "All release script tests passed."
    exit 0
else
    echo "$FAILURES release script test(s) failed." >&2
    exit 1
fi
