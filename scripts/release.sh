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
# actually produced the artifact — not whatever HEAD happens to be after a potentially long
# `make bundle`. Without this, a checkout to a different (but still clean, so the
# re-verification below wouldn't catch it) commit mid-build would get the version tag while the
# published asset still contains the EARLIER commit's code.
BUILD_COMMIT="$(git rev-parse HEAD)"

echo "==> Building and signing the bundle"
# VERSION_OVERRIDE stamps the bundle with this already-validated version directly, without
# needing a git tag to exist first — the tag itself is created only as the very last local step
# below (see the top-of-file comment), so `git describe` can't be used as the stamping source
# here the way plain `make bundle` uses it for dev builds. Passed as a `make` command-line
# assignment, which `make` exports to the recipe's shell environment automatically, so the
# Makefile reads it as a real shell variable — never textually inlined by Make into recipe text.
make bundle CODESIGN_IDENTITY="$CODESIGN_IDENTITY" VERSION_OVERRIDE="$VERSION"

BUNDLE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_NAME.app/Contents/Info.plist")"
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
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ASSET_PATH"

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

# Re-verify cleanliness AFTER the (potentially long) build, not just before it — an edit made
# during `make bundle` would otherwise get signed, zipped, and published under this tag without
# ever having been checked. Same exit-status check as the pre-build one above — a failing
# `git status --porcelain` must not read as "clean."
if ! GIT_STATUS_OUTPUT="$(git status --porcelain)"; then
    echo "error: 'git status --porcelain' failed — cannot verify the working tree is clean." >&2
    exit 1
fi
if [[ -n "$GIT_STATUS_OUTPUT" ]]; then
    echo "error: working tree changed during the build — commit or discard the changes and" >&2
    echo "re-run. Nothing has been tagged, pushed, or published." >&2
    exit 1
fi

# A clean `git status` only means no UNCOMMITTED changes — it says nothing about whether HEAD
# itself moved to a different (already-committed) commit mid-build, which is exactly the
# scenario that binding the tag to $BUILD_COMMIT (recorded before the build) protects against.
# Surface that explicitly rather than silently tagging a commit other than the one just built.
CURRENT_COMMIT="$(git rev-parse HEAD)"
if [[ "$CURRENT_COMMIT" != "$BUILD_COMMIT" ]]; then
    echo "error: HEAD moved from $BUILD_COMMIT to $CURRENT_COMMIT during the build — the built" >&2
    echo "asset was produced from $BUILD_COMMIT. Nothing has been tagged, pushed, or published;" >&2
    echo "re-run from the commit you want to release." >&2
    exit 1
fi

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
