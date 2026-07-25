#!/bin/bash
# scripts/release.sh — builds, signs, and publishes a FreeTalker release.
#
# Usage:
#   scripts/release.sh vMAJOR.MINOR.PATCH [--dry-run]
#
# Steps: tag HEAD -> build+sign a versioned bundle (`make bundle`, never `make app`/`install` —
# this script must never touch /Applications) -> zip -> checksum -> write a manifest -> push the
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

if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "error: tag $VERSION already exists." >&2
    exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]] && ! command -v gh >/dev/null 2>&1; then
    echo "error: gh (GitHub CLI) is required to publish a release. Install it or pass --dry-run." >&2
    exit 1
fi

echo "==> Tagging $VERSION at $(git rev-parse --short HEAD)"
if [[ "$DRY_RUN" -eq 0 ]]; then
    git tag -a "$VERSION" -m "FreeTalker $VERSION"
else
    echo "(dry run — not tagging)"
fi

echo "==> Building and signing the bundle"
make bundle CODESIGN_IDENTITY="$CODESIGN_IDENTITY"

BUNDLE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_NAME.app/Contents/Info.plist")"
if [[ "$DRY_RUN" -eq 0 && "$BUNDLE_VERSION" != "$VERSION" ]]; then
    echo "error: built bundle reports version '$BUNDLE_VERSION', expected '$VERSION' — the tag" >&2
    echo "wasn't at HEAD when \`make bundle\` ran \`git describe\`. Aborting before publishing." >&2
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

echo "==> Pushing tag $VERSION"
git push origin "$VERSION"

echo "==> Publishing GitHub release $VERSION"
gh release create "$VERSION" "$ASSET_PATH" "$MANIFEST_PATH" \
    --repo "$REPO_SLUG" \
    --title "$VERSION" \
    --notes "FreeTalker $VERSION. Signed with the FreeTalker Dev certificate — see README.md for how to allow it on first launch."

echo "==> Done. $VERSION is live at https://github.com/$REPO_SLUG/releases/tag/$VERSION"
