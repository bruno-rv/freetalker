#!/bin/bash
# scripts/release.sh — builds, signs, and publishes a FreeTalker release.
#
# Usage:
#   scripts/release.sh vMAJOR.MINOR.PATCH [--dry-run]
#
# Steps: validate everything that can be validated up front (clean tree, signing identity,
# release-signing key, gh authentication) -> build+sign a versioned bundle (`make bundle`, never
# `make app`/`install` — this script must never touch /Applications) -> zip -> checksum -> sign
# the zip with the Ed25519 release-signing key -> write a manifest -> re-verify the tree is
# still clean -> tag the EXACT commit that produced the artifact (the last local step, so a
# build failure never leaves a dangling tag blocking a rerun) -> push the tag and publish a
# GitHub release. `--dry-run` stops after the manifest (dist/ is left on disk for inspection)
# and never tags, pushes, or publishes anything.
#
# Every release is signed TWICE, for two different purposes:
#   - codesign, with the same local self-signed "FreeTalker Dev" certificate
#     (scripts/make-signing-cert.sh) — purely so TCC permission grants (Accessibility, Input
#     Monitoring, Microphone) survive rebuilds. This is NOT a security/trust mechanism; macOS
#     refuses to validate a self-signed cert's trust chain on any machine that hasn't manually
#     marked it "Always Trust."
#   - Ed25519 (scripts/make-release-signing-key.sh) — the actual authenticity boundary.
#     SelfUpdater verifies this signature against the public key compiled into the running app,
#     which has no keychain/trust-chain dependency at all. If this key is ever lost and a new
#     one generated, every already-built app fails verification loudly (it can only trust the
#     one public key compiled in) rather than silently accepting anything — that failure mode is
#     the intended replacement for the certificate-continuity pinning this script used to do.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="bruno-rv/freetalker"
APP_NAME="FreeTalker"

DRY_RUN=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        v*) VERSION="$arg" ;;
        *)
            echo "error: unrecognized argument: $arg" >&2
            echo "usage: scripts/release.sh vMAJOR.MINOR.PATCH [--dry-run]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "usage: scripts/release.sh vMAJOR.MINOR.PATCH [--dry-run]" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like vMAJOR.MINOR.PATCH (got: $VERSION)" >&2
    exit 1
fi

# Reconstructs a PEM Ed25519 public key from the raw 32-byte base64 value UpdatePublicKey.swift
# stores (see scripts/make-release-signing-key.sh's `derive_public_key_base64`, which goes the
# other direction). `302a300506032b6570032100` is the fixed 12-byte SubjectPublicKeyInfo header
# for Ed25519 (RFC 8410: SEQUENCE(AlgorithmIdentifier(OID 1.3.101.112), BIT STRING(32 bytes))) —
# confirmed byte-for-byte against `openssl pkey -pubout`'s own DER output for a real generated
# key, not assumed. Used by the post-sign verification below (Round-4 Finding 2) to turn
# BUILD_COMMIT's own compiled-in public key into something `openssl pkeyutl -verify` can check
# a signature against, without needing the PRIVATE key at all.
reconstruct_public_key_pem() {
    local base64_raw_key="$1" out_pem="$2"
    local der_hex
    der_hex="302a300506032b6570032100$(printf '%s' "$base64_raw_key" | openssl base64 -A -d 2>/dev/null | xxd -p | tr -d '\n')"
    printf '%s' "$der_hex" | xxd -r -p | openssl pkey -pubin -inform DER -pubout -out "$out_pem" 2>/dev/null
}

cd "$REPO_ROOT"

# `git status --porcelain` can itself fail (e.g. a broken/misconfigured git environment) and
# exit non-zero with EMPTY stdout — checking only "is the output non-empty" would then read as
# "clean" and let a release proceed with no actual cleanliness check at all. Check the exit
# status explicitly, not just the output, here and in the re-verification after the build below.
if ! GIT_STATUS_OUTPUT="$(git status --porcelain)"; then
    echo "error: 'git status --porcelain' failed — cannot verify the working tree is clean." >&2
    exit 1
fi
if [[ -n "$GIT_STATUS_OUTPUT" ]]; then
    echo "error: working tree has uncommitted changes — commit or discard them before releasing." >&2
    exit 1
fi

if [[ ! -f .codesign-identity ]]; then
    echo "error: .codesign-identity not found. Run scripts/make-signing-cert.sh and record the" >&2
    echo "identity first (see README.md)." >&2
    exit 1
fi
CODESIGN_IDENTITY="$(cat .codesign-identity)"
if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "error: .codesign-identity must name a real signing identity, not ad-hoc (-)." >&2
    echo "Ad-hoc rebuilds drop TCC grants — see README.md's \"Stable signing identity\" section." >&2
    exit 1
fi

# The Ed25519 private key is the actual authenticity boundary for every existing install (see
# UpdateSignatureVerifier.swift) — fail closed here, before any build work, rather than
# discovering it's missing after already building and zipping the bundle.
RELEASE_SIGNING_KEY="${FREETALKER_RELEASE_SIGNING_KEY:-$HOME/.freetalker/release-signing-key.pem}"
if [[ ! -f "$RELEASE_SIGNING_KEY" ]]; then
    echo "error: release signing key not found at $RELEASE_SIGNING_KEY." >&2
    echo "Run scripts/make-release-signing-key.sh once to generate it (see README.md)." >&2
    exit 1
fi

# A release signed with a key whose PUBLIC half doesn't match the one compiled into every
# existing app (UpdatePublicKey.swift) would verify against NOTHING — every existing client
# would reject it. This happens for real: an interrupted
# scripts/make-release-signing-key.sh run can leave a PEM whose public half was never written to
# UpdatePublicKey.swift, or $FREETALKER_RELEASE_SIGNING_KEY can simply point at a different valid
# key. Derive the public key from THIS key, the exact same way
# scripts/make-release-signing-key.sh derived the compiled-in one, and refuse to proceed on any
# mismatch — before any build work, same as the missing-key check above.
PUBLIC_KEY_SWIFT="$REPO_ROOT/Sources/FreeTalker/Update/UpdatePublicKey.swift"
COMPILED_PUBLIC_KEY_BASE64="$(sed -n 's/.*base64 = "\([^"]*\)".*/\1/p' "$PUBLIC_KEY_SWIFT")"
if [[ -z "$COMPILED_PUBLIC_KEY_BASE64" ]]; then
    echo "error: could not read the compiled-in public key from $PUBLIC_KEY_SWIFT." >&2
    exit 1
fi
if ! DERIVED_PUBLIC_KEY_BASE64="$(
    openssl pkey -in "$RELEASE_SIGNING_KEY" -pubout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | tail -c 32 | openssl base64 -A
)" || [[ -z "$DERIVED_PUBLIC_KEY_BASE64" ]]; then
    echo "error: could not derive a public key from $RELEASE_SIGNING_KEY — is it a valid Ed25519" >&2
    echo "private key?" >&2
    exit 1
fi
if [[ "$DERIVED_PUBLIC_KEY_BASE64" != "$COMPILED_PUBLIC_KEY_BASE64" ]]; then
    echo "error: the release signing key at $RELEASE_SIGNING_KEY does NOT match the public key" >&2
    echo "compiled into every existing build ($PUBLIC_KEY_SWIFT). Signing with it would publish" >&2
    echo "a release every existing client rejects. Refusing to proceed." >&2
    echo "If you just ran scripts/make-release-signing-key.sh and it was interrupted, re-run it" >&2
    echo "to resume (it will bring $PUBLIC_KEY_SWIFT back in sync with the existing key)." >&2
    exit 1
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "error: tag $VERSION already exists." >&2
    exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh (GitHub CLI) is required to publish a release. Install it or pass --dry-run." >&2
        exit 1
    fi
    # Validate everything that CAN be validated before creating or pushing any tag (see
    # "Tagging" below) — an unauthenticated `gh` used to let the tag get created and pushed
    # before `gh release create` failed, leaving a tag with no release and forcing a manual
    # `git tag -d`/`git push --delete` before a rerun could even start.
    if ! gh auth status >/dev/null 2>&1; then
        echo "error: gh is installed but not authenticated (gh auth status failed). Run" >&2
        echo "'gh auth login' first, or pass --dry-run." >&2
        exit 1
    fi
fi

# Recorded BEFORE the build so the tag created at the end is bound to the exact commit that
# actually produced the artifact.
BUILD_COMMIT="$(git rev-parse HEAD)"

# Build from a PRISTINE checkout of $BUILD_COMMIT in its own throwaway `git worktree` — never
# from this working tree. This is what actually proves provenance rather than merely narrowing
# the window: a `git status`/`HEAD` re-check against THIS tree after the build (the previous
# approach) reads clean whenever a concurrent actor checks out a different commit, lets `make
# bundle` build THAT commit's code, and checks back to $BUILD_COMMIT before the check runs —
# `git worktree add --detach` instead checks out ONLY $BUILD_COMMIT's committed content into a
# directory nothing else knows about or has any reason to touch, so nothing happening in this
# tree (an uncommitted edit, a checkout away and back, anything) can influence the artifact at
# all, no matter the timing.
WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/freetalker-release-XXXXXX")"
cleanup_worktree() {
    git worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || rm -rf "$WORKTREE_DIR"
}
trap cleanup_worktree EXIT
echo "==> Checking out $(git rev-parse --short "$BUILD_COMMIT") into an isolated worktree"
git worktree add --quiet --detach "$WORKTREE_DIR" "$BUILD_COMMIT"

echo "==> Building and signing the bundle"
# VERSION_OVERRIDE stamps the bundle with this already-validated version directly, without
# needing a git tag to exist first — the tag itself is created only as the very last local step
# below (see the top-of-file comment), so `git describe` can't be used as the stamping source
# here the way plain `make bundle` uses it for dev builds. Passed as a `make` command-line
# assignment, which `make` exports to the recipe's shell environment automatically, so the
# Makefile reads it as a real shell variable — never textually inlined by Make into recipe text.
# Run inside the isolated worktree (not $REPO_ROOT) — see above.
( cd "$WORKTREE_DIR" && make bundle CODESIGN_IDENTITY="$CODESIGN_IDENTITY" VERSION_OVERRIDE="$VERSION" )

BUNDLE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$WORKTREE_DIR/$APP_NAME.app/Contents/Info.plist")"
if [[ "$BUNDLE_VERSION" != "$VERSION" ]]; then
    echo "error: built bundle reports version '$BUNDLE_VERSION', expected '$VERSION'." >&2
    exit 1
fi

DIST_DIR="dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ASSET_NAME="$APP_NAME-$VERSION.app.zip"
ASSET_PATH="$DIST_DIR/$ASSET_NAME"

echo "==> Zipping (ditto, to preserve the code signature)"
ditto -c -k --sequesterRsrc --keepParent "$WORKTREE_DIR/$APP_NAME.app" "$ASSET_PATH"

echo "==> Computing checksum"
SHA256="$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')"
echo "$SHA256  $ASSET_NAME" > "$ASSET_PATH.sha256"

# The Ed25519 signature — not the checksum above — is the actual authenticity boundary
# (UpdateSignatureVerifier.swift). `-rawin` is required for Ed25519: unlike RSA/ECDSA, it signs
# the whole message directly rather than a pre-hashed digest, so this must be run against the
# exact same bytes SelfUpdater downloads and verifies (the zip, not some derived checksum file).
echo "==> Signing with the release Ed25519 key"
SIGNATURE_PATH="$ASSET_PATH.sig"
openssl pkeyutl -sign -inkey "$RELEASE_SIGNING_KEY" -rawin -in "$ASSET_PATH" -out "$SIGNATURE_PATH"
SIGNATURE_BASE64="$(openssl base64 -A -in "$SIGNATURE_PATH")"

# The pre-build check above (COMPILED_PUBLIC_KEY_BASE64 vs DERIVED_PUBLIC_KEY_BASE64) validates
# that $RELEASE_SIGNING_KEY matches the LIVE tree's UpdatePublicKey.swift — read BEFORE the build,
# from a path nothing here holds any lock on. Two live sequences can still slip a mismatched
# signature past that alone: (a) $RELEASE_SIGNING_KEY's PEM path gets atomically replaced with a
# different (but validly Ed25519) key partway through the multi-second `make bundle` above —
# `openssl pkeyutl -sign` just reopened the path and signed with whatever's there NOW, which may
# no longer be what was validated; (b) commit B's public key gets validated in the live tree,
# then the live tree is checked out to commit A before $BUILD_COMMIT is captured, so `make bundle`
# builds A's source (in the isolated worktree) while still signing with the key that matches B.
# Neither is caught by re-checking the LIVE tree afterward (a compromised/racing actor can just as
# easily have restored it to look clean by then) — verifying the signature just produced against
# BUILD_COMMIT's OWN compiled-in public key, read from the pristine worktree `make bundle` itself
# built from (never the live tree), closes both regardless of what changed mid-flight or when:
# whatever key the artifact ends up verifying against IS, by construction, the one every client
# built from BUILD_COMMIT actually trusts.
echo "==> Verifying the signature against BUILD_COMMIT's own compiled-in public key"
PRISTINE_PUBLIC_KEY_SWIFT="$WORKTREE_DIR/Sources/FreeTalker/Update/UpdatePublicKey.swift"
# `|| true` keeps a missing/unreadable BUILD_COMMIT source (e.g. an older commit that predates
# UpdatePublicKey.swift entirely, reached via --dry-run testing against an old BUILD_COMMIT, or
# any other checkout that simply lacks the file) from being fatal here under `set -e`: `sed`
# exits nonzero on ENOENT with no stdout, and since this assignment is a bare simple command,
# set -e would otherwise abort the whole script on the spot — skipping the -z check right below
# and, with it, the `rm -rf "$DIST_DIR"` cleanup that check performs. Falling through to that
# check with an empty value here treats "missing source file" exactly like "empty/unreadable
# key", which is already handled the same way "does not verify" is: abort AND clean up dist/.
PRISTINE_PUBLIC_KEY_BASE64="$(sed -n 's/.*base64 = "\([^"]*\)".*/\1/p' "$PRISTINE_PUBLIC_KEY_SWIFT" 2>/dev/null || true)"
if [[ -z "$PRISTINE_PUBLIC_KEY_BASE64" ]]; then
    echo "error: could not read the compiled-in public key from BUILD_COMMIT's own source" >&2
    echo "($PRISTINE_PUBLIC_KEY_SWIFT)." >&2
    rm -rf "$DIST_DIR"
    exit 1
fi
PRISTINE_PUBLIC_KEY_PEM="$WORKTREE_DIR/.build-verify-pubkey.pem"
if ! reconstruct_public_key_pem "$PRISTINE_PUBLIC_KEY_BASE64" "$PRISTINE_PUBLIC_KEY_PEM" || [[ ! -s "$PRISTINE_PUBLIC_KEY_PEM" ]]; then
    echo "error: could not reconstruct a public key from BUILD_COMMIT's compiled-in base64" >&2
    echo "($PRISTINE_PUBLIC_KEY_SWIFT) — is it a valid 32-byte raw Ed25519 public key?" >&2
    rm -rf "$DIST_DIR"
    exit 1
fi
if ! openssl pkeyutl -verify -pubin -inkey "$PRISTINE_PUBLIC_KEY_PEM" -rawin -in "$ASSET_PATH" -sigfile "$SIGNATURE_PATH" >/dev/null 2>&1; then
    echo "error: the signature just produced does NOT verify against BUILD_COMMIT's own" >&2
    echo "compiled-in public key ($PRISTINE_PUBLIC_KEY_SWIFT). The key actually used to sign no" >&2
    echo "longer matches what was validated before the build, or BUILD_COMMIT's own public key" >&2
    echo "differs from what was validated — refusing to publish an artifact that every client" >&2
    echo "built from BUILD_COMMIT would reject." >&2
    # Removed, not left behind for someone to accidentally hand-publish: this is a real, validly
    # zipped/checksummed artifact, just signed with (or compiled against) the wrong key — nothing
    # about its own shape looks obviously broken.
    rm -rf "$DIST_DIR"
    exit 1
fi
echo "==> Signature verified against BUILD_COMMIT's own compiled-in public key"

MANIFEST_PATH="$DIST_DIR/latest.json"
ASSET_URL="https://github.com/$REPO_SLUG/releases/download/$VERSION/$ASSET_NAME"
cat > "$MANIFEST_PATH" <<EOF
{
  "version": "$VERSION",
  "assetURL": "$ASSET_URL",
  "sha256": "$SHA256",
  "signature": "$SIGNATURE_BASE64"
}
EOF

echo "==> Wrote $ASSET_PATH ($(du -h "$ASSET_PATH" | cut -f1)), $ASSET_PATH.sha256, $ASSET_PATH.sig, and $MANIFEST_PATH"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "==> Dry run complete — nothing tagged, pushed, or published. Inspect $DIST_DIR/."
    exit 0
fi

# No re-verification of THIS tree's cleanliness/HEAD is needed here (a previous version of this
# script did, as a "narrow the window" mitigation): the artifact was built from an isolated
# worktree pinned to $BUILD_COMMIT (see above), so nothing that happened in this tree during the
# build — an edit, a checkout away and back, anything — could have influenced it. What gets
# tagged below and what got built are provably the same commit by construction, not by a
# best-effort check that a sufficiently-timed race could still slip past.

# Tag the exact commit the artifact was built from ($BUILD_COMMIT, recorded before `make
# bundle`), not "HEAD" — the last local step before anything is pushed or published, so a
# failure anywhere above (including a build/codesign failure, which used to happen AFTER
# tagging) never leaves a tag that blocks a rerun with "tag already exists."
echo "==> Tagging $VERSION at $(git rev-parse --short "$BUILD_COMMIT")"
git tag -a "$VERSION" -m "FreeTalker $VERSION" "$BUILD_COMMIT"

echo "==> Pushing tag $VERSION"
git push origin "$VERSION"

echo "==> Publishing GitHub release $VERSION"
gh release create "$VERSION" "$ASSET_PATH" "$MANIFEST_PATH" \
    --repo "$REPO_SLUG" \
    --title "$VERSION" \
    --notes "FreeTalker $VERSION. Signed with the FreeTalker Dev certificate (for TCC-grant stability) and the Ed25519 release-signing key (for update verification) — see README.md for how to allow the app on first launch."

echo "==> Done. $VERSION is live at https://github.com/$REPO_SLUG/releases/tag/$VERSION"
