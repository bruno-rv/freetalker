#!/bin/bash
# scripts/make-signing-cert.sh — one-time setup for a stable local code-signing identity.
#
# Ad-hoc signing (`codesign -s -`) gives every rebuild a different signature, so macOS
# treats each build as a new app and drops previously granted TCC permissions
# (Accessibility, Input Monitoring, Microphone). A self-signed "Code Signing" certificate
# in the login keychain lets `make app CODESIGN_IDENTITY="FreeTalker Dev"` sign with a
# stable identity instead, so grants survive rebuilds.
#
# Run this ONCE, manually:
#   scripts/make-signing-cert.sh
#
# macOS won't let a script grant a self-signed cert "Always Trust" for code signing without
# GUI/admin interaction, so the last step below is manual: open Keychain Access and mark
# the cert as trusted. This script is a convenience for that setup, not a product.

set -euo pipefail

IDENTITY_NAME="FreeTalker Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if security find-identity -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "A codesigning identity named \"$IDENTITY_NAME\" already exists. Nothing to do."
    echo "Build with: make app CODESIGN_IDENTITY=\"$IDENTITY_NAME\""
    exit 0
fi

echo "Creating self-signed code signing certificate \"$IDENTITY_NAME\"..."

KEY_FILE="$WORKDIR/freetalker-dev.key"
CERT_FILE="$WORKDIR/freetalker-dev.crt"
P12_FILE="$WORKDIR/freetalker-dev.p12"
P12_PASSWORD="$(openssl rand -base64 24)"

# Self-signed cert with the codeSigning extended key usage — required for codesign to
# accept it as a valid signing identity.
openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -days 3650 -nodes -subj "/CN=$IDENTITY_NAME" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature"

openssl pkcs12 -export -out "$P12_FILE" -inkey "$KEY_FILE" -in "$CERT_FILE" \
    -name "$IDENTITY_NAME" -passout "pass:$P12_PASSWORD"

# -T /usr/bin/codesign lets codesign use the private key without a per-invocation keychain
# access prompt.
security import "$P12_FILE" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign

echo
echo "Certificate imported into $KEYCHAIN."
echo
echo "One manual step remains — macOS requires GUI confirmation to trust a self-signed"
echo "code-signing cert:"
echo "  1. Open Keychain Access, select the \"login\" keychain, \"My Certificates\" category."
echo "  2. Find \"$IDENTITY_NAME\", double-click it, expand \"Trust\"."
echo "  3. Set \"Code Signing\" to \"Always Trust\", close the panel, and enter your password."
echo
echo "Then build with the stable identity:"
echo "  make app CODESIGN_IDENTITY=\"$IDENTITY_NAME\""
echo
echo "To make 'Check for Updates…' rebuilds use it too, record it at the repo root:"
echo "  echo \"$IDENTITY_NAME\" > \"$REPO_ROOT/.codesign-identity\""
