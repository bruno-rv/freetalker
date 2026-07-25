APP_NAME := FreeTalker
BUNDLE := $(APP_NAME).app
CONFIG := release
BIN := .build/$(CONFIG)/$(APP_NAME)
RESOURCE_BUNDLE := .build/$(CONFIG)/$(APP_NAME)_$(APP_NAME).bundle
RESOURCE_BUNDLE_NAME := $(APP_NAME)_$(APP_NAME).bundle
XCODE_DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
# Ad-hoc by default so plain `make app` is unchanged. Set to a real identity (see
# scripts/make-signing-cert.sh) so TCC grants survive rebuilds instead of being orphaned by
# ad-hoc signing's per-build signature.
CODESIGN_IDENTITY ?= -
# If scripts/make-signing-cert.sh recorded a stable identity at the repo root, use it by
# default so TCC grants survive rebuilds. An explicit CODESIGN_IDENTITY=... on the command
# line still wins (command-line assignments override file assignments).
#
# `.codesign-identity` is a file anyone with write access to this checkout controls (and
# `release.sh` separately passes its content through on the `make bundle` command line — see
# release.sh), so its contents are exactly as untrusted as a hostile git tag (see the big
# comment above `VERSION_OVERRIDE`) — a value like
# `x"; cp /tmp/payload FreeTalker.app/Contents/MacOS/FreeTalker; chmod +x ...; #` was able to
# break out of the `codesign` recipe line's quoting and run as arbitrary shell when this value
# was substituted textually via `$(CODESIGN_IDENTITY)`. `codesign-identity-check` below closes
# that by reading it as a real shell variable, `"$$CODESIGN_IDENTITY"`, never `$(CODESIGN_IDENTITY)`.
#
# That alone is NOT sufficient, though: `:=` below (not the `=` this used to be) matters just as
# much. GNU Make variables using `=` (or a plain command-line assignment, which defaults to the
# same "recursive" semantics) are RE-EXPANDED as Make syntax every single time they're
# referenced — including every time `export` needs to compute the value to hand a recipe's shell
# environment. A `.codesign-identity` containing literal text like `$(shell touch /pwned)` would
# make Make itself execute `touch /pwned` as a real shell command at every such expansion — not
# a quoting bug at all, and not something any shell-side allowlist can intercept, because the
# execution happens inside MAKE'S OWN variable expansion, before any recipe (including
# `codesign-identity-check`) ever runs. `:=` instead expands the right-hand side exactly ONCE,
# at this line, and stores the resulting text as an inert, static string forever after — so even
# file content that LOOKS like Make syntax is never re-interpreted as Make syntax again.
ifneq ($(wildcard .codesign-identity),)
CODESIGN_IDENTITY := $(shell cat .codesign-identity)
endif
# Command-line assignments (`make bundle CODESIGN_IDENTITY=...`, which is how release.sh passes
# the value it read from `.codesign-identity`) default to that same dangerous recursive
# semantics REGARDLESS of the `:=` used for the file-based default above — a command-line value
# containing `$(shell ...)` would still be re-executed on every export otherwise. `override ...
# := $(value CODESIGN_IDENTITY)` re-captures whatever CODESIGN_IDENTITY currently holds (the
# `-` default, the file-based value above, or a command-line override — `override` lets the
# makefile win regardless of which) as a simple variable one more time. `$(value ...)` is what
# makes this safe rather than merely redundant: it returns a variable's UNEXPANDED text — so if
# the current value is a command-line-supplied `$(shell touch /pwned)`, this line captures that
# literal text WITHOUT ever asking Make to evaluate it as a function call. Verified directly
# (`make CODESIGN_IDENTITY='$(shell touch /tmp/x)'` with and without this line) — without it,
# `/tmp/x` gets created; with it, `$$CODESIGN_IDENTITY` in a recipe sees the literal, inert
# string `$(shell touch /tmp/x)`, which `codesign-identity-check`'s allowlist then rejects like
# any other malformed identity.
override CODESIGN_IDENTITY := $(value CODESIGN_IDENTITY)
# `export` now hands recipes' shell environments this already-inert, already-captured string —
# a plain environment-variable copy, not a fresh Make-syntax expansion — so
# `codesign-identity-check` and the `bundle` recipe can both read it as `"$$CODESIGN_IDENTITY"`,
# a shell variable expansion inside double quotes, which never re-parses its own contents for
# quotes/semicolons/Make-function-syntax no matter what they contain.
export CODESIGN_IDENTITY

INSTALLED_BUNDLE := /Applications/$(BUNDLE)

# The app's version, baked into the bundle's Info.plist by `bundle` below (see Update/AppVersion.swift
# and SemanticVersion.swift, which parse this same `git describe` shape). A tagged release (see
# scripts/release.sh) always builds at an exact tag, so CI-free local dev builds between tags
# (with a "-N-gHASH[-dirty]" suffix) never get published — only clean tags do.
#
# Deliberately NOT a `:=` Make variable substituted into recipe text: Make expands `$(VAR)`
# textually into the shell command line BEFORE the shell ever parses it, so a hostile tag name
# like `v1.2.3";id>/tmp/pwned;#` (a valid git ref — `git check-ref-format` allows it) would break
# out of the quoting in any recipe line that embeds it and execute as shell. `git describe`'s
# output is untrusted precisely because it depends on whatever tags happen to be reachable from
# HEAD, which for anyone who fetched a hostile tag is attacker-controlled. Every recipe below
# instead captures it into a real shell variable via `$$(git describe ...)` (command
# substitution, evaluated BY THE SHELL, not textually by Make) and both validates it against a
# strict allowlist and only ever references it as `"$$ver"` — a shell variable expansion, which
# never re-parses its own contents for quotes/semicolons no matter what they contain.
#
# VERSION_OVERRIDE lets scripts/release.sh stamp the bundle with a version it has already
# strictly validated (`^vMAJOR.MINOR.PATCH$`), before any git tag for it exists — release.sh
# creates that tag only as its very last local step, specifically so a build/codesign failure
# never leaves a dangling tag blocking a rerun. `make` exports a command-line assignment like
# this to the recipe's shell environment automatically, so the recipe below reads it as the
# real shell variable `$$VERSION_OVERRIDE` — never as a Make-substituted `$(VERSION_OVERRIDE)` —
# for the same reason `git describe`'s output above is never substituted directly either.
VERSION_OVERRIDE ?=

# Strict allowlist for a codesigning identity: either the literal ad-hoc marker `-`, or a string
# starting with an alphanumeric and containing only characters that are actually seen in real
# `security find-identity -p codesigning` output — letters, digits, spaces, and
# `. , : ( ) @ -` (covers both a plain name like "FreeTalker Dev" and Apple's own
# "Developer ID Application: Name (TEAMID)" shape) — capped at a generous but bounded length. No
# `'` (apostrophe): not just untrusted-value hygiene but a literal shell-quoting constraint here,
# since this pattern is itself embedded in a single-quoted argument to `grep` below — an
# apostrophe in the pattern would prematurely close THAT quoting the same way an attacker's
# unescaped one would. Deliberately excludes `"`, `` ` ``, `$`, `\`, `;`, `&`, `|`, `<`, `>`, and
# all control characters (including newlines): none of those ever appear in a legitimate identity,
# and each is exactly what a shell-injection payload needs. This is checked in ADDITION to (never
# instead of) reading the value as a real shell variable — see `export CODESIGN_IDENTITY` above —
# so a value that somehow slipped past this regex still could not break out of its quoting.
CODESIGN_IDENTITY_ALLOWLIST_PATTERN := ^(-|[A-Za-z0-9][A-Za-z0-9 .,:()@-]{0,127})$$

.PHONY: build test test-preflight bundle app install run clean codesign-identity-check

build:
	swift build -c $(CONFIG)

test: test-preflight
	@echo "Using Xcode developer directory: $(XCODE_DEVELOPER_DIR)"
	DEVELOPER_DIR="$(XCODE_DEVELOPER_DIR)" swift test

test-preflight:
	@test -x "$(XCODE_DEVELOPER_DIR)/usr/bin/xcodebuild" || \
		( echo "error: full Xcode is required for tests; xcodebuild not found under $(XCODE_DEVELOPER_DIR)" >&2; exit 1 )
	@test -d "$(XCODE_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework" || \
		( echo "error: Swift Testing framework not found under $(XCODE_DEVELOPER_DIR)" >&2; exit 1 )

# Validates `$$CODESIGN_IDENTITY` (see `export CODESIGN_IDENTITY` above) against the strict
# allowlist BEFORE `bundle` does any build work, and BEFORE it ever reaches the `codesign` recipe
# line below. Pulled out as its own target (rather than inlined only at the point of use) so it's
# independently testable via a plain `make codesign-identity-check` against a fixture — see
# scripts/test-makefile-codesign-identity.sh — without needing a full `swift build` first.
codesign-identity-check:
	@identity="$$CODESIGN_IDENTITY"; \
	stripped="$$(printf '%s' "$$identity" | tr -d '\n')"; \
	if [ "$$stripped" != "$$identity" ]; then \
		echo "error: CODESIGN_IDENTITY contains a newline — refusing it outright, regardless of" >&2; \
		echo "the allowlist below: grep -E's \"^...\$\$\" anchors match per LINE, not the whole" >&2; \
		echo "value, so a value crafted as \"<harmless first line>\\n<anything>\" could otherwise" >&2; \
		echo "pass the check below on its first line while smuggling arbitrary trailing content." >&2; exit 1; \
	fi; \
	printf '%s' "$$identity" | grep -Eq '$(CODESIGN_IDENTITY_ALLOWLIST_PATTERN)' || { \
		echo "error: CODESIGN_IDENTITY failed strict validation: $$identity" >&2; \
		echo "(refusing to pass an untrusted signing identity into any shell command — see" >&2; \
		echo "README.md's \"Stable signing identity\" section)" >&2; exit 1; \
	}

# Assembles FreeTalker.app from the built executable and stamps it with the version from
# `git describe` (validated below) — no .xcodeproj available (CLT only), see README.md. Does
# NOT touch /Applications — see `app`
# below for that. This split exists so scripts/release.sh (and anything else that needs a
# signed, versioned bundle without disturbing the installed copy) can depend on `bundle` alone.
# `codesign-identity-check` runs FIRST (before `build`) so a bad identity fails fast, before
# spending time on a build whose result would just be discarded.
bundle: codesign-identity-check build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	mkdir -p $(BUNDLE)/Contents/Resources/$(RESOURCE_BUNDLE_NAME)/Contents/Resources
	cp -R $(RESOURCE_BUNDLE)/. $(BUNDLE)/Contents/Resources/$(RESOURCE_BUNDLE_NAME)/Contents/Resources/
	cp Assets/SettingsIconsInfo.plist $(BUNDLE)/Contents/Resources/$(RESOURCE_BUNDLE_NAME)/Contents/Info.plist
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	@if [ -n "$$VERSION_OVERRIDE" ]; then \
		ver="$$VERSION_OVERRIDE"; \
	else \
		ver="$$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)"; \
	fi; \
	printf '%s' "$$ver" | grep -Eq '^(v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+-g[0-9a-f]+)?|[0-9a-f]{4,40})(-dirty)?$$' || { \
		echo "error: version string from 'git describe' failed strict validation: $$ver" >&2; \
		echo "(refusing to pass an untrusted tag name into any shell command)" >&2; exit 1; \
	}; \
	plutil -replace CFBundleShortVersionString -string "$$ver" $(BUNDLE)/Contents/Info.plist; \
	plutil -replace CFBundleVersion -string "$$ver" $(BUNDLE)/Contents/Info.plist; \
	echo "Built $(BUNDLE) ($$ver)."
	cp Assets/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp Assets/FreeTalker.sdef $(BUNDLE)/Contents/Resources/FreeTalker.sdef
	codesign --force --deep -s "$$CODESIGN_IDENTITY" $(BUNDLE)
	@# Defense in depth beyond `codesign`'s own exit status: re-verify the signature that's now
	@# actually on disk rather than trusting that a zero exit from the line above means the
	@# bundle is correctly signed. This recipe line has no `;`/`&&` chaining an attacker's
	@# injected identity could exploit to mask a failure (see `codesign-identity-check` above),
	@# and Make already aborts the build on any recipe command's non-zero exit with no `-`/`@`
	@# prefix suppressing that — this step exists purely as an independent, direct check of the
	@# actual on-disk result, not as a substitute for either of those guarantees.
	codesign --verify --deep --strict $(BUNDLE)

# Assembles the bundle (see `bundle` above) and installs it into /Applications.
app: bundle
	@echo "Launch with: open $(BUNDLE)"
ifeq ($(CODESIGN_IDENTITY),-)
	@echo "NOTE: ad-hoc signing (-s -) gives this build a signature that differs from the"
	@echo "previous one whenever the binary changed. If PTT or hotkey capture stop responding"
	@echo "after this rebuild, remove FreeTalker from System Settings > Privacy & Security >"
	@echo "Accessibility (and Input Monitoring) and re-add it, even if it still shows as on."
endif
	$(MAKE) install

# Copies the freshly built bundle into /Applications, replacing any previous install.
# Quits a running instance first so the overwrite doesn't clobber an open app.
install:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALLED_BUNDLE)
	cp -R $(BUNDLE) $(INSTALLED_BUNDLE)
	@echo "Installed $(INSTALLED_BUNDLE)."

run: app
	open $(INSTALLED_BUNDLE)

clean:
	rm -rf .build $(BUNDLE)
