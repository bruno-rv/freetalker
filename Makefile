APP_NAME := FreeTalker
BUNDLE := $(APP_NAME).app
CONFIG := release
BIN := .build/$(CONFIG)/$(APP_NAME)

.PHONY: build test app run clean

build:
	swift build -c $(CONFIG)

test:
	swift test

# Assembles FreeTalker.app from the built executable — no .xcodeproj available (CLT only),
# see README.md.
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp Assets/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --deep -s - $(BUNDLE)
	@echo "Built $(BUNDLE). Launch with: open $(BUNDLE)"
	@echo "NOTE: ad-hoc signing (-s -) gives this build a signature that differs from the"
	@echo "previous one whenever the binary changed. If PTT or hotkey capture stop responding"
	@echo "after this rebuild, remove FreeTalker from System Settings > Privacy & Security >"
	@echo "Accessibility (and Input Monitoring) and re-add it, even if it still shows as on."

run: app
	open $(BUNDLE)

clean:
	rm -rf .build $(BUNDLE)
