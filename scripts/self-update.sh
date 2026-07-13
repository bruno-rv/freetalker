#!/bin/bash
# scripts/self-update.sh — flight path for FreeTalker's "Check for Updates…" menu action.
# Invoked by SelfUpdater.swift as: self-update.sh <caller-pid> <repo-path>, detached and
# not awaited (FreeTalker terminates right after spawning it). Waits for the calling
# FreeTalker process to quit, then pulls, rebuilds, and relaunches.
#
# ponytail: `make app` overwrites FreeTalker.app before the new build is verified to run;
# if the build fails partway, the previous bundle may already be gone and FreeTalker stays
# closed. Upgrade path: build into a temp location and swap atomically on success. Not
# worth the complexity for a single-user personal app — on failure, check
# /tmp/freetalker-update.log and rerun `make app` manually.

set -euo pipefail

LOG_FILE="/tmp/freetalker-update.log"
CALLER_PID="${1:?missing caller pid}"
REPO_PATH="${2:?missing repo path}"
CURRENT_STEP="startup"

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

notify_failure() {
    osascript -e "display notification \"Failed: ${CURRENT_STEP}\" with title \"FreeTalker Update\"" >/dev/null 2>&1 || true
    log "FAILED at: ${CURRENT_STEP}"
}
trap notify_failure ERR

log "Starting update for pid ${CALLER_PID}, repo ${REPO_PATH}"

CURRENT_STEP="waiting for FreeTalker to quit"
WAITED=0
while kill -0 "$CALLER_PID" 2>/dev/null; do
    if [ "$WAITED" -ge 30 ]; then
        log "timed out waiting for pid ${CALLER_PID} to exit"
        trap - ERR
        notify_failure
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

CURRENT_STEP="git pull --ff-only origin main"
git -C "$REPO_PATH" pull --ff-only origin main >> "$LOG_FILE" 2>&1

# Repo-local opt-in for a stable signing identity (see scripts/make-signing-cert.sh and
# README) — a plain string file, not shell-sourced, so its contents never get evaluated.
CODESIGN_ARG=""
if [ -f "$REPO_PATH/.codesign-identity" ]; then
    IDENTITY="$(cat "$REPO_PATH/.codesign-identity")"
    if [ -n "$IDENTITY" ]; then
        CODESIGN_ARG="CODESIGN_IDENTITY=$IDENTITY"
    fi
fi

CURRENT_STEP="make app"
if [ -n "$CODESIGN_ARG" ]; then
    make -C "$REPO_PATH" app "$CODESIGN_ARG" >> "$LOG_FILE" 2>&1
else
    make -C "$REPO_PATH" app >> "$LOG_FILE" 2>&1
fi

CURRENT_STEP="open FreeTalker.app"
open "$REPO_PATH/FreeTalker.app"

log "Update complete, relaunched from ${REPO_PATH}/FreeTalker.app"
