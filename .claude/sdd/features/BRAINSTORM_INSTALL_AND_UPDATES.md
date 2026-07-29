# BRAINSTORM: Installable App and Real Updates

**Phase:** 0 — Brainstorm
**Date:** 2026-07-24
**Status:** Ready for `/define`
**Feature slug:** `INSTALL_AND_UPDATES`

---

## Problem

FreeTalker cannot leave the machine it was built on.

- The app updates itself only by pulling from git and recompiling, which requires the running
  app to sit inside its own source clone (`Update/SelfUpdater.swift:47-54` — refuses with
  *"app not running from its repo"*), plus git, make and a Swift toolchain on the machine
  (`scripts/self-update.sh:45-63`).
- There is **no version number**. `Info.plist` is static at `1.0` / `1`, there are no git
  tags, and no build-time stamping anywhere. Nothing in the project can answer "which build
  is this?".
- There is **no release artifact and no CI**. No `.github/`, no release script, no tags.
- There is **no first-run experience**. Permissions are primed silently at launch
  (`App.swift:43-56`); Screen Recording only ever on a Settings button
  (`SettingsView.swift:571`); the ~954 MB speech model downloads automatically with nothing
  but a menu-bar status line to show for it (`SpeechModelCatalog.swift:16,52`,
  `WhisperKitEngine.swift:667,686`). The only walkthrough lives in `README.md:87-108`.

### Bug found during discovery

The uncommitted `Makefile` change moved the canonical app location to `/Applications`
(`install` target; `app` now auto-installs; `run` opens the installed copy). `SelfUpdater`
was never updated to match and still requires the bundle's parent directory to be a git
working tree. **Self-update is currently broken for the app you are running.** This feature
subsumes the fix.

---

## Scope decision (important)

The round opened aiming at a public release: anyone downloads, drags to Applications, opens.
That requires Apple to vouch for the app, which requires a paid Apple Developer account.
**Decision: no Apple Developer account — so that goal is explicitly dropped.** macOS will
block first launch and no engineering on our side changes that.

Also ruled out on the way in: the Mac App Store, since the app types into other applications'
text fields, which App Store rules forbid.

**Re-scoped goal:** the app becomes installable anywhere and updates itself without needing
its source folder, its compiler, or a re-grant of permissions. Audience is people comfortable
enough to allow an unsigned-by-Apple app once.

---

## Decisions (from discovery)

| # | Question | Decision |
|---|----------|----------|
| 1 | Audience? | Re-scoped: **installable + self-updating**, not publicly distributable |
| 2 | How do updates arrive? | **The app downloads a finished build and swaps itself** |
| 3 | Keep the rebuild-from-source path? | **No — replace it.** One update mechanism |
| 4 | First run? | **A guided walkthrough** — permissions in order with live status, model download with progress |
| 5 | Who signs releases? | **Locally, with the existing `FreeTalker Dev` certificate.** Key never leaves the machine |
| 6 | How is it proven? | **Hand it to someone and watch them install it** |

---

## Approach

### 1. Give the app a version
Stamped into the bundle at build time from a git tag. Everything else depends on this
existing.

### 2. Releases are finished builds
Tagging produces a signed, zipped app published as a GitHub release. Nobody installing needs
git, make, or a Swift compiler. Release is a script run locally: build → sign → zip →
publish.

### 3. The app updates itself safely
Check the release list, download the newer build to a temporary location, **verify it
launches**, and only then swap and restart.

This closes a hazard the project already documents against itself
(`scripts/self-update.sh:7-11`, tagged `# ponytail:`): today `make app` overwrites the
installed app *before* the new build is known to work, so a failed rebuild leaves the user
with no app at all. Download-verify-swap removes that class of failure.

The git-pull-and-recompile path is deleted, not kept alongside. Two update mechanisms that
can disagree about what's installed is exactly the failure the current bug demonstrates.

### 4. Guided first run
One window on first launch: each permission in order with live granted/not-granted status and
a button that takes the user to the right place, then the speech model download with visible
progress. The point is that nobody ends up in a half-working state pressing a hotkey that
does nothing.

### 5. Signing and Gatekeeper — stated plainly
Every release is signed with the same self-made `FreeTalker Dev` certificate
(`scripts/make-signing-cert.sh`). This certificate is **not trusted by Apple and never will
be**; its job is different. macOS ties microphone, accessibility and input-monitoring grants
to an app's signature, so a *stable* signature means those permissions survive updates.
An unsigned or per-build-signed release would force everyone — including the author — to
re-grant everything after every update, undoing the reason the certificate was created
(`Makefile:8-10`).

First launch is therefore: macOS blocks it once, the person explicitly allows it once, and
never again. That step gets documented and shown in the walkthrough.

The private key stays on the author's machine. No automated build service, so no copy of a
signing key in the cloud — worth noting because this certificate is unverified by anyone, so
a leaked key means anything can be signed as "FreeTalker".

---

## YAGNI — cut

| Cut | Why |
|-----|-----|
| Notarization / public distribution | Needs a paid Apple account. Explicitly declined |
| Mac App Store | Forbidden by App Store rules for an app that types into other apps |
| Automated build service (CI) | Releases are infrequent and the signing key should stay local. Add later if release friction becomes real |
| Homebrew tap | Not needed once the app updates itself. Reconsider if people ask to install by command |
| Delta / partial updates | The whole app is a few tens of MB. The 954 MB model is downloaded separately and already persists across updates |
| Rollback to a previous version | Re-downloading an older release covers it |

---

## Validation

**Hand the build to someone and watch them install it**, without helping. This is the only
test that catches confusion rather than defects — where they hesitate, misread a step, or
conclude the app is broken. Every one of those moments is a bug in the walkthrough.

Supplementary, repeatable, and free: a fresh macOS user account on the author's own Mac is
genuinely blank (permissions are per-account, so no grants, no model, no settings) and can be
reset between attempts. Good for regression, useless for confusion.

---

## Draft requirements for `/define`

1. The app carries a real version, derived from a git tag at build time.
2. A local release script produces a signed, zipped app and publishes it as a tagged release.
3. All releases are signed with the same stable self-made certificate, so permission grants
   survive updates.
4. The app checks for newer releases, downloads to a temporary location, verifies the new
   build launches, then swaps itself and restarts.
5. A failed or interrupted update never leaves the user without a working app.
6. The git-pull-and-rebuild update path is removed, along with its assumption that the bundle
   lives inside its source clone.
7. The app updates itself correctly when installed in `/Applications` with no source present.
8. First launch presents a walkthrough: each required permission in order with live status,
   then the speech model download with visible progress.
9. Pressing the dictation hotkey while a prerequisite is missing explains what is missing
   rather than doing nothing.
10. Documentation states plainly that macOS will block the first launch and how to allow it.

---

**Next:** `/define .claude/sdd/features/BRAINSTORM_INSTALL_AND_UPDATES.md`
