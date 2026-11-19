# Perch — keep any window perched above your other apps.
#
#   make test      unit tests
#   make app       build .build/local/Perch.app
#   make run       build it and open it
#   make install   build it and copy it to /Applications
#   make clean     remove the built apps
#
# Needs nothing beyond the Xcode 26 command line tools (Swift 6.2) or later.

BUNDLE_NAME      := Perch
PRODUCT_NAME     := Perch.app
BUNDLE_ID        := tech.sugarhouse.Perch
SPM_PRODUCT      := Perch
ENTITLEMENTS     := Perch.entitlements

# Personal settings (signing identity, bundle ID), kept out of the repo.
-include local.mk

.DEFAULT_GOAL := app

LOCAL_APP        := .build/local/$(PRODUCT_NAME)
LOCAL_BUNDLE_ID  ?= $(BUNDLE_ID)
# "-" signs ad hoc. Set a Developer ID ("Developer ID Application: …") to sign
# with the hardened runtime and a secure timestamp; a stable signature also
# keeps Accessibility and Screen Recording granted across rebuilds.
LOCAL_SIGN_ID    ?= -
ifeq ($(LOCAL_SIGN_ID),-)
LOCAL_SIGN_FLAGS :=
else
LOCAL_SIGN_FLAGS := --options runtime --timestamp
endif
# /Applications, not ~/Applications: on macOS 26 and later, menu bar managers
# such as Bartender do not see the menu bar items of apps run from elsewhere.
INSTALL_DIR      ?= /Applications
LSREGISTER       := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PLISTBUDDY       := /usr/libexec/PlistBuddy

.PHONY: app install run test clean

# Unit tests: the logic, with no windows, permissions or screen capture.
# Swift Testing runs them in parallel; the older XCTest suites run alongside.
test:
	swift test

app:
	swift build -c release --product $(SPM_PRODUCT) && \
	BIN="$$(swift build -c release --show-bin-path)/$(SPM_PRODUCT)" && \
	rm -rf "$(LOCAL_APP)" && \
	mkdir -p "$(LOCAL_APP)/Contents/MacOS" "$(LOCAL_APP)/Contents/Resources" && \
	cp "$$BIN" "$(LOCAL_APP)/Contents/MacOS/$(BUNDLE_NAME)" && \
	cp -R Resources/ "$(LOCAL_APP)/Contents/Resources/" && \
	cp Info.plist "$(LOCAL_APP)/Contents/Info.plist" && \
	$(PLISTBUDDY) -c "Set :CFBundleIdentifier $(LOCAL_BUNDLE_ID)" "$(LOCAL_APP)/Contents/Info.plist" && \
	codesign --force --sign "$(LOCAL_SIGN_ID)" $(LOCAL_SIGN_FLAGS) --entitlements $(ENTITLEMENTS) "$(LOCAL_APP)" && \
	codesign --verify --strict "$(LOCAL_APP)" && \
	echo "Built $(LOCAL_APP)"

install: app
	mkdir -p "$(INSTALL_DIR)" && \
	rm -rf "$(INSTALL_DIR)/$(PRODUCT_NAME)" && \
	ditto "$(LOCAL_APP)" "$(INSTALL_DIR)/$(PRODUCT_NAME)" && \
	( $(LSREGISTER) -u "$(CURDIR)/$(LOCAL_APP)" >/dev/null 2>&1 || true ) && \
	echo "Installed $(INSTALL_DIR)/$(PRODUCT_NAME)"

# `install` leaves only the installed copy known to Launch Services; a second
# registered copy of the app in the build folder confuses System Settings'
# permission lists.
#
# Quit a copy already running from this bundle first; otherwise `open` just
# brings the old process forward and the new build never starts.
run: app
	pkill -f "$(CURDIR)/$(LOCAL_APP)/Contents/MacOS/" && sleep 1 || true; \
	open "$(LOCAL_APP)"

clean:
	rm -rf .build/local
