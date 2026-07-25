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
ifneq ($(wildcard .codesign-identity),)
CODESIGN_IDENTITY = $(shell cat .codesign-identity)
endif

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

.PHONY: build test test-preflight bundle app install run clean

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

# Assembles FreeTalker.app from the built executable and stamps it with the version from
# `git describe` (validated below) — no .xcodeproj available (CLT only), see README.md. Does
# NOT touch /Applications — see `app`
# below for that. This split exists so scripts/release.sh (and anything else that needs a
# signed, versioned bundle without disturbing the installed copy) can depend on `bundle` alone.
bundle: build
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
	codesign --force --deep -s "$(CODESIGN_IDENTITY)" $(BUNDLE)

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
