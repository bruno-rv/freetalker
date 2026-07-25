#!/bin/bash
# scripts/make-release-signing-key.sh — one-time setup for the Ed25519 release-signing keypair.
#
# scripts/release.sh signs every release artifact with the PRIVATE half of this keypair;
# SelfUpdater verifies that signature against the PUBLIC half, which is compiled into the app
# (Sources/FreeTalker/Update/UpdatePublicKey.swift, GENERATED at build time — see
# scripts/generate-update-public-key.sh and Plugins/GenerateUpdatePublicKey — from
# keys/release-public-key.base64, which THIS script writes). This is the actual trust boundary
# for self-update — unlike codesign trust-chain validation (which fails closed with
# CSSMERR_TP_NOT_TRUSTED on every machine except the one where a human manually marked the
# self-signed cert "Always Trust" in Keychain Access), it never depends on any machine's local
# keychain trust, so it verifies identically everywhere the app runs.
#
# Run this ONCE, manually, and only ever on the machine that publishes releases:
#   scripts/make-release-signing-key.sh
#
# The PRIVATE key is written OUTSIDE this repository (default: ~/.freetalker/) and must never
# be committed — losing it means no future release can ever be verified as authentic by an app
# that already has the current public key compiled in; there is no recovery path other than
# generating a new keypair and shipping a build with the new public key, which every existing
# install must then separately be told to trust again. Back the private key up somewhere safe
# (a password manager or an encrypted volume) as soon as this script finishes.
#
# Resumable by design: if this is killed after the PEM is written but before
# keys/release-public-key.base64 is updated to match it, re-running does NOT silently treat "the
# PEM exists" as "nothing to do" (that was a real bug — a rerun exited 0 while the established
# public key still didn't match the private key on disk, so scripts/release.sh would go on to
# sign every release with a key no existing app could verify). It compares the PEM's actual
# public half against what's established and, on any mismatch, resumes by rewriting
# keys/release-public-key.base64 from the EXISTING private key — it never generates a new
# keypair over an existing one.
#
# That mismatch check has exactly one blind spot, closed below: it cannot tell "resuming a setup
# that was genuinely interrupted before keys/release-public-key.base64 was ever written" (no
# ESTABLISHED public key to protect — safe to auto-repair) apart from
# "keys/release-public-key.base64 already holds a real, established anchor that simply disagrees
# with THIS key" (e.g. FREETALKER_RELEASE_SIGNING_KEY accidentally points at a different, but
# still validly Ed25519, key B, while deployed clients and the tracked data file trust key A) —
# both look identical as "PEM exists, established key doesn't match it." Silently "resuming" the
# second case overwrites A with B and tells the operator to commit it: every future release, now
# signed with B, is rejected by every already-installed A-pinned client — a silent,
# self-inflicted update-channel outage with no error at any point. The distinction is the
# established key's PRESENCE: empty/absent means nothing has been established yet (safe to
# auto-repair); any other value is an anchor real installs already depend on (refuse without
# --rotate-established-key, see below).
#
# keys/release-public-key.base64 (read and written by read_established_public_key_base64 /
# write_public_key_data_file, scripts/lib/public-key-data-file.sh) holds ONLY the base64 value —
# no Swift source is read or written by this script at all. Rounds 5-7 all found new ways for
# shell code parsing hand-written Swift to disagree with what Swift itself would compile; moving
# the checked-in trust anchor into a plain data file with no Swift syntax in it removes that
# entire bug class rather than tightening it further.

set -euo pipefail

ROTATE_ESTABLISHED_KEY=0
for arg in "$@"; do
    case "$arg" in
        --rotate-established-key) ROTATE_ESTABLISHED_KEY=1 ;;
        *)
            echo "error: unrecognized argument: $arg" >&2
            echo "usage: scripts/make-release-signing-key.sh [--rotate-established-key]" >&2
            exit 1
            ;;
    esac
done

KEY_DIR="${FREETALKER_RELEASE_SIGNING_KEY_DIR:-$HOME/.freetalker}"
PRIVATE_KEY_PATH="${FREETALKER_RELEASE_SIGNING_KEY:-$KEY_DIR/release-signing-key.pem}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_KEY_DATA_FILE="$REPO_ROOT/keys/release-public-key.base64"

# shellcheck source=lib/public-key-data-file.sh
source "$REPO_ROOT/scripts/lib/public-key-data-file.sh"

# Derives the base64 raw 32-byte Ed25519 public key from a private key PEM, on stdout. Fails
# (nonzero exit, nothing printed) if the input isn't a readable Ed25519 private key, or if the
# derived SubjectPublicKeyInfo DER isn't exactly the expected 44 bytes (12-byte algorithm-ID
# header + 32-byte raw key — see the size check below) — refusing to hand back something that
# might not be the raw 32-byte key CryptoKit's `Curve25519.Signing.PublicKey(rawRepresentation:)`
# expects, rather than silently truncating/misreading it.
derive_public_key_base64() {
    local private_key_path="$1"
    local public_key_pem public_key_der der_size
    public_key_pem="$(mktemp)"
    public_key_der="$(mktemp)"
    trap 'rm -f "$public_key_pem" "$public_key_der"' RETURN
    openssl pkey -in "$private_key_path" -pubout -out "$public_key_pem" 2>/dev/null || return 1
    openssl pkey -pubin -in "$public_key_pem" -outform DER -out "$public_key_der" 2>/dev/null || return 1
    der_size="$(wc -c <"$public_key_der" | tr -d ' ')"
    [[ "$der_size" -eq 44 ]] || return 1
    tail -c 32 "$public_key_der" | openssl base64 -A
}

write_public_key_data_file() {
    local public_key_base64="$1"
    mkdir -p "$(dirname "$PUBLIC_KEY_DATA_FILE")"
    printf '%s\n' "$public_key_base64" >"$PUBLIC_KEY_DATA_FILE"
}

# Read the established public key ONCE, up front — both branches below (PEM exists / PEM
# missing) need to know whether $PUBLIC_KEY_DATA_FILE already holds an ESTABLISHED anchor, and
# must see EXACTLY the same answer scripts/release.sh's own read would (they share the same
# read_established_public_key_base64). A nonzero return here means the file exists but could not
# be safely read as either "nothing established yet" or "a valid anchor" (MALFORMED source) —
# fail closed immediately, before even checking whether a private key exists, rather than
# falling through to either "resume" or "nothing to do" on the basis of a file that couldn't be
# read.
if ! CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64="$(read_established_public_key_base64 "$PUBLIC_KEY_DATA_FILE")"; then
    echo "error: $PUBLIC_KEY_DATA_FILE exists but could not be safely read as either a genuine" >&2
    echo "placeholder (nothing established yet) or a valid established anchor — see the error" >&2
    echo "above. This is NOT treated as either of those states, because doing so could either" >&2
    echo "skip the established-anchor guard when an anchor really is there, or report" >&2
    echo "\"nothing to do\" while leaving a broken file in place. Investigate and fix" >&2
    echo "$PUBLIC_KEY_DATA_FILE by hand (or restore it from git) before re-running." >&2
    exit 1
fi

if [[ -f "$PRIVATE_KEY_PATH" ]]; then
    if ! EXISTING_PUBLIC_KEY_BASE64="$(derive_public_key_base64 "$PRIVATE_KEY_PATH")" || [[ -z "$EXISTING_PUBLIC_KEY_BASE64" ]]; then
        echo "error: $PRIVATE_KEY_PATH exists but isn't a readable Ed25519 private key." >&2
        echo "Investigate manually — refusing to touch it or generate a new one over it." >&2
        exit 1
    fi
    if [[ "$CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64" == "$EXISTING_PUBLIC_KEY_BASE64" ]]; then
        echo "A release signing key already exists at $PRIVATE_KEY_PATH, and $PUBLIC_KEY_DATA_FILE"
        echo "already matches it. Nothing to do."
        echo "Delete the PEM manually first if you really want to generate a new one — doing so makes"
        echo "every already-built app (which has the OLD public key compiled in) unable to verify"
        echo "any release signed with the new key, until it's rebuilt with the new one."
        exit 0
    fi
    # The PEM exists but the established public key doesn't match it. Two situations look
    # IDENTICAL at this point and must NOT be handled the same way (see the top-of-file comment):
    # a genuinely interrupted first-time setup — nothing has been established yet, so
    # $PUBLIC_KEY_DATA_FILE is missing or holds no real key — versus an ESTABLISHED anchor that
    # simply disagrees with this PEM (already-deployed clients trust it). The established key's
    # PRESENCE is what tells them apart. (A file that exists but can't be safely read either way
    # already exited above — CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64 here is only ever a real value
    # or genuinely empty, never "unreadable.")
    if [[ -z "$CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64" ]]; then
        # Nothing established yet — RESUME by deriving from the EXISTING private key and
        # (re)writing keys/release-public-key.base64 to match. Never generates a new keypair,
        # which would orphan every already-built app the same way deleting-and-regenerating
        # would (moot here anyway, since nothing has been built against any key yet).
        echo "$PRIVATE_KEY_PATH exists but $PUBLIC_KEY_DATA_FILE doesn't have an established key"
        echo "yet — resuming an apparently interrupted first-time run. The private key is left"
        echo "untouched; only $PUBLIC_KEY_DATA_FILE is (re)written, from the EXISTING key."
        write_public_key_data_file "$EXISTING_PUBLIC_KEY_BASE64"
        echo
        echo "Public key written to: $PUBLIC_KEY_DATA_FILE — commit this file."
        exit 0
    fi
    if [[ "$ROTATE_ESTABLISHED_KEY" -ne 1 ]]; then
        echo "error: $PUBLIC_KEY_DATA_FILE already has an ESTABLISHED public key" >&2
        echo "($CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64), and it does NOT match the key at" >&2
        echo "$PRIVATE_KEY_PATH ($EXISTING_PUBLIC_KEY_BASE64)." >&2
        echo >&2
        echo "This is NOT treated as an interrupted first-time setup, because a real anchor" >&2
        echo "already exists: every app already built and installed trusts the CURRENTLY" >&2
        echo "established key. If \$PRIVATE_KEY_PATH ($PRIVATE_KEY_PATH) is simply the wrong" >&2
        echo "file — e.g. FREETALKER_RELEASE_SIGNING_KEY points somewhere unintended — fix that" >&2
        echo "and re-run instead of overriding this." >&2
        echo >&2
        echo "If you are deliberately rotating the release-signing key (the established private" >&2
        echo "key was lost or compromised), understand the consequence first: every already-" >&2
        echo "installed app, which can only ever trust the ONE public key it was compiled with," >&2
        echo "will reject every future release signed with the new key as unverified, with no" >&2
        echo "further warning at release time — each install must be separately rebuilt and" >&2
        echo "redistributed with the new key before it can accept new releases again." >&2
        echo "If that's genuinely what you intend, re-run with --rotate-established-key." >&2
        exit 1
    fi
    echo "--rotate-established-key was passed — overwriting the established public key at"
    echo "$PUBLIC_KEY_DATA_FILE ($CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64) with the one derived"
    echo "from $PRIVATE_KEY_PATH ($EXISTING_PUBLIC_KEY_BASE64). Every already-installed app"
    echo "pinned to the old key will reject future releases until it's rebuilt with this new one."
    write_public_key_data_file "$EXISTING_PUBLIC_KEY_BASE64"
    echo
    echo "Public key written to: $PUBLIC_KEY_DATA_FILE — commit this file."
    exit 0
fi

# No file at $PRIVATE_KEY_PATH. The established-anchor guard above applies here too — a missing
# PEM (a typo in $FREETALKER_RELEASE_SIGNING_KEY, a lost key, or a fresh publisher workstation)
# must NOT be treated as "nothing established yet" just because there's no file to compare
# against. If $PUBLIC_KEY_DATA_FILE already holds a real anchor, falling through to key
# generation below would silently mint a brand-new key and overwrite it — exactly the
# destructive case this guard exists for, and losing the private key does not make it safer to
# do so silently: there is no way back once an already-deployed anchor is rotated out from under
# it. (CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64 was already read once, up front, before either
# branch — see above.)
if [[ -n "$CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64" && "$ROTATE_ESTABLISHED_KEY" -ne 1 ]]; then
    echo "error: $PRIVATE_KEY_PATH does not exist, but $PUBLIC_KEY_DATA_FILE already has an" >&2
    echo "ESTABLISHED public key ($CURRENT_ESTABLISHED_PUBLIC_KEY_BASE64)." >&2
    echo >&2
    echo "This is NOT treated as a fresh first-time setup, because a real anchor already" >&2
    echo "exists: every app already built and installed trusts the CURRENTLY established key." >&2
    echo "Generating a brand-new key here would silently overwrite that anchor — every" >&2
    echo "already-installed app, which can only ever trust the ONE public key it was compiled" >&2
    echo "with, would reject every future release signed with the new key, with no further" >&2
    echo "warning at release time — each install must be separately rebuilt and redistributed" >&2
    echo "with the new key before it can accept new releases again." >&2
    echo >&2
    echo "If \$PRIVATE_KEY_PATH ($PRIVATE_KEY_PATH) is simply the wrong path — e.g." >&2
    echo "FREETALKER_RELEASE_SIGNING_KEY points somewhere unintended, or the key file was" >&2
    echo "moved/lost — fix that and re-run instead of overriding this." >&2
    echo >&2
    echo "If you are deliberately rotating the release-signing key (the established private" >&2
    echo "key was lost or compromised), understand the consequence first, same as above. If" >&2
    echo "that's genuinely what you intend, re-run with --rotate-established-key." >&2
    exit 1
fi

PRIVATE_KEY_DIR="$(dirname "$PRIVATE_KEY_PATH")"
mkdir -p "$PRIVATE_KEY_DIR"
chmod 700 "$PRIVATE_KEY_DIR"

echo "Generating Ed25519 release-signing keypair..."
# Generated into a temp file in the SAME directory (so the final `mv` below is a same-volume
# rename, not a copy) and moved into place only once fully written and mode-600 — makes the
# PRIVATE KEY's own creation atomic. A process killed mid-`genpkey` (or between writing it and
# `chmod`) can then never leave a truncated, or briefly-world-readable, file AT
# $PRIVATE_KEY_PATH for a later run (or anything else) to mistake for a complete, properly
# permissioned key.
TMP_PRIVATE_KEY_PATH="$(mktemp "$PRIVATE_KEY_DIR/.release-signing-key.XXXXXX")"
trap 'rm -f "$TMP_PRIVATE_KEY_PATH"' EXIT
openssl genpkey -algorithm ED25519 -out "$TMP_PRIVATE_KEY_PATH"
chmod 600 "$TMP_PRIVATE_KEY_PATH"
mv "$TMP_PRIVATE_KEY_PATH" "$PRIVATE_KEY_PATH"
trap - EXIT

if ! PUBLIC_KEY_BASE64="$(derive_public_key_base64 "$PRIVATE_KEY_PATH")" || [[ -z "$PUBLIC_KEY_BASE64" ]]; then
    echo "error: generated $PRIVATE_KEY_PATH but could not derive its public key (or the" >&2
    echo "derived SubjectPublicKeyInfo DER wasn't the expected 44 bytes) — refusing to write a" >&2
    echo "public key that might not be the raw 32-byte key CryptoKit expects. The private key" >&2
    echo "is still at $PRIVATE_KEY_PATH; re-run this script to resume once investigated." >&2
    exit 1
fi
write_public_key_data_file "$PUBLIC_KEY_BASE64"

echo
echo "Private key written to: $PRIVATE_KEY_PATH (outside this repo, mode 600)."
echo "Public key written to: $PUBLIC_KEY_DATA_FILE — commit this file."
echo "(Sources/FreeTalker/Update/UpdatePublicKey.swift is generated from it automatically the"
echo "next time FreeTalker is built — see Plugins/GenerateUpdatePublicKey — nothing else to do.)"
echo
echo "IMPORTANT: back up $PRIVATE_KEY_PATH somewhere safe right now. If it's lost, no future"
echo "release can ever be verified by an app already built with this public key."
echo
echo "scripts/release.sh reads the private key from \$FREETALKER_RELEASE_SIGNING_KEY (default:"
echo "$PRIVATE_KEY_PATH)."
