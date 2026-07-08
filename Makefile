APP_NAME := FreeTalker
BUNDLE := $(APP_NAME).app
CONFIG := release
BIN := .build/$(CONFIG)/$(APP_NAME)

.PHONY: build app run test clean selfcheck

build:
	swift build -c $(CONFIG)

# Assembles FreeTalker.app from the built executable — no .xcodeproj available (CLT only),
# see README.md.
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --deep -s - $(BUNDLE)
	@echo "Built $(BUNDLE). Launch with: open $(BUNDLE)"
	@echo "NOTE: ad-hoc signing (-s -) gives this build a signature that differs from the"
	@echo "previous one whenever the binary changed. If PTT or hotkey capture stop responding"
	@echo "after this rebuild, remove FreeTalker from System Settings > Privacy & Security >"
	@echo "Accessibility (and Input Monitoring) and re-add it, even if it still shows as on."

run: app
	open $(BUNDLE)

# Runs the FTS/template-seeding check without relying on the (broken, CLT-only) XCTest/
# swift-testing runtime — see SelfCheck.swift and README "Running tests".
selfcheck: build
	$(BIN) --self-check

# `swift test` compiles Tests/FreeTalkerTests but cannot execute in this CLT-only environment
# (Testing.framework's runtime dylibs aren't shipped outside Xcode). Kept for parity with a
# full Xcode toolchain; use `make selfcheck` for a guaranteed-runnable check today.
test:
	swift build --build-tests -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks

clean:
	rm -rf .build $(BUNDLE)
