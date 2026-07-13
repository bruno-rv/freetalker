APP_NAME := FreeTalker
BUNDLE := $(APP_NAME).app
CONFIG := release
BIN := .build/$(CONFIG)/$(APP_NAME)
RESOURCE_BUNDLE := .build/$(CONFIG)/$(APP_NAME)_$(APP_NAME).bundle
RESOURCE_BUNDLE_NAME := $(APP_NAME)_$(APP_NAME).bundle
XCODE_DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: build test test-preflight app run clean

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

# Assembles FreeTalker.app from the built executable — no .xcodeproj available (CLT only),
# see README.md.
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	mkdir -p $(BUNDLE)/Contents/Resources/$(RESOURCE_BUNDLE_NAME)/Contents/Resources
	cp -R $(RESOURCE_BUNDLE)/. $(BUNDLE)/Contents/Resources/$(RESOURCE_BUNDLE_NAME)/Contents/Resources/
	cp Assets/SettingsIconsInfo.plist $(BUNDLE)/Contents/Resources/$(RESOURCE_BUNDLE_NAME)/Contents/Info.plist
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
