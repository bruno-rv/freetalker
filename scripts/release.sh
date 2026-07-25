#!/bin/bash
# scripts/release.sh — builds, signs, and publishes a FreeTalker release.
#
# Usage:
#   scripts/release.sh vMAJOR.MINOR.PATCH [--dry-run] [--allow-identity-change]
#
# Steps: validate everything that can be validated up front (clean tree, signing identity,
# recorded certificate fingerprint, gh authentication) -> build+sign a versioned bundle
# (`make bundle`, never `make app`/`install` — this script must never touch /Applications) ->
# zip -> checksum -> write a manifest -> re-verify the tree is still clean -> tag HEAD (the
# LAST local step, so a build failure never leaves a dangling tag blocking a rerun) -> push the
# tag and publish a GitHub release. `--dry-run` stops after the manifest (dist/ is left on disk
# for inspection) and never tags, pushes, or publishes anything.
#
# Every release is signed with the same local self-signed "FreeTalker Dev" certificate
# (scripts/make-signing-cert.sh) — never notarized, never a paid Apple Developer identity (see
# BRAINSTORM_INSTALL_AND_UPDATES.md's "Scope decision"). SelfUpdater.swift pins the running
# app's own certificate fingerprint, so releases must all share that one identity or existing
# installs will refuse to trust them.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="bruno-rv/freetalker"
APP_NAME="FreeTalker"

DRY_RUN=0
ALLOW_IDENTITY_CHANGE=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --allow-identity-change) ALLOW_IDENTITY_CHANGE=1 ;;
        v*) VERSION="$arg" ;;
        *)
            echo "error: unrecognized argument: $arg" >&2
            echo "usage: scripts/release.sh vMAJOR.MINOR.PATCH [--dry-run] [--allow-identity-change]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "usage: scripts/release.sh vMAJOR.MINOR.PATCH [--dry-run] [--allow-identity-change]" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like vMAJOR.MINOR.PATCH (got: $VERSION)" >&2
    exit 1
fi

cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
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
    echo "Releases must all share one stable identity — see SelfUpdater.swift's fingerprint pin." >&2
    exit 1
fi

# Every existing install pins the *exact certificate* behind this identity name (see
# CodeSignatureVerifier.swift) — not just the name "FreeTalker Dev". Regenerating a same-named
# cert (e.g. after `scripts/make-signing-cert.sh` is re-run on a new machine) and publishing
# under it would produce releases no existing client can ever accept, permanently splitting
# update continuity for everyone already on a previous release, with no error message pointing
# at why. Record the leaf certificate's fingerprint the first time a release succeeds, and
# refuse to publish under a different one afterward without an explicit override.
IDENTITY_FINGERPRINT_FILE=".codesign-identity-fingerprint"
IDENTITY_CERT_DER="$(mktemp)"
trap 'rm -f "$IDENTITY_CERT_DER"' EXIT
if ! security find-certificate -c "$CODESIGN_IDENTITY" -p >"$IDENTITY_CERT_DER" 2>/dev/null; then
    echo "error: no certificate named \"$CODESIGN_IDENTITY\" found in any keychain." >&2
    exit 1
fi
CURRENT_IDENTITY_FINGERPRINT="$(openssl x509 -in "$IDENTITY_CERT_DER" -noout -fingerprint -sha256 | awk -F= '{print $2}' | tr -d ':')"
if [[ -f "$IDENTITY_FINGERPRINT_FILE" ]]; then
    RECORDED_IDENTITY_FINGERPRINT="$(cat "$IDENTITY_FINGERPRINT_FILE")"
    if [[ "$RECORDED_IDENTITY_FINGERPRINT" != "$CURRENT_IDENTITY_FINGERPRINT" ]]; then
        if [[ "$ALLOW_IDENTITY_CHANGE" -eq 0 ]]; then
            echo "error: the certificate behind \"$CODESIGN_IDENTITY\" changed since the last release." >&2
            echo "  recorded: $RECORDED_IDENTITY_FINGERPRINT" >&2
            echo "  current:  $CURRENT_IDENTITY_FINGERPRINT" >&2
            echo "Every existing install pins the exact certificate, not just this name — publishing" >&2
            echo "under a new one splits update continuity for anyone already on a previous release." >&2
            echo "Pass --allow-identity-change to publish anyway (updates the recorded fingerprint)." >&2
            exit 1
        fi
        echo "==> --allow-identity-change: publishing under a new certificate fingerprint."
    fi
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

MANIFEST_PATH="$DIST_DIR/latest.json"
ASSET_URL="https://github.com/$REPO_SLUG/releases/download/$VERSION/$ASSET_NAME"
cat > "$MANIFEST_PATH" <<EOF
{
  "version": "$VERSION",
  "assetURL": "$ASSET_URL",
  "sha256": "$SHA256"
}
EOF

echo "==> Wrote $ASSET_PATH ($(du -h "$ASSET_PATH" | cut -f1)), $ASSET_PATH.sha256, and $MANIFEST_PATH"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "==> Dry run complete — nothing tagged, pushed, or published. Inspect $DIST_DIR/."
    exit 0
fi

# Re-verify cleanliness AFTER the (potentially long) build, not just before it — an edit made
# during `make bundle` would otherwise get signed, zipped, and published under this tag without
# ever having been checked.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree changed during the build — commit or discard the changes and" >&2
    echo "re-run. Nothing has been tagged, pushed, or published." >&2
    exit 1
fi

# Tag HEAD only now — the last local step before anything is pushed or published, so a failure
# anywhere above (including a build/codesign failure, which used to happen AFTER tagging) never
# leaves a tag that blocks a rerun with "tag already exists."
echo "==> Tagging $VERSION at $(git rev-parse --short HEAD)"
git tag -a "$VERSION" -m "FreeTalker $VERSION"

echo "==> Pushing tag $VERSION"
git push origin "$VERSION"

echo "==> Publishing GitHub release $VERSION"
gh release create "$VERSION" "$ASSET_PATH" "$MANIFEST_PATH" \
    --repo "$REPO_SLUG" \
    --title "$VERSION" \
    --notes "FreeTalker $VERSION. Signed with the FreeTalker Dev certificate — see README.md for how to allow it on first launch."

echo "$CURRENT_IDENTITY_FINGERPRINT" > "$IDENTITY_FINGERPRINT_FILE"

echo "==> Done. $VERSION is live at https://github.com/$REPO_SLUG/releases/tag/$VERSION"
