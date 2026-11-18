#!/bin/bash
# Builds the downloadable Perch: universal (Apple silicon and Intel), signed
# with a Developer ID, notarised by Apple, with the ticket stapled so
# Gatekeeper accepts it offline. Run it through `make release`.
#
# It is repeatable on purpose: it refuses a dirty tree, builds from scratch,
# takes the version from Info.plist and the build number from the commit, and
# writes a SHA-256 beside the zip. The same commit gives the same app.
#
# Needs, once per machine:
#   - LOCAL_SIGN_ID in local.mk set to "Developer ID Application: … (TEAMID)"
#   - a notarytool keychain profile (default name perch-notary):
#       xcrun notarytool store-credentials perch-notary \
#           --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#     (it asks for an app-specific password from account.apple.com)
set -euo pipefail

SIGN_ID="${LOCAL_SIGN_ID:?LOCAL_SIGN_ID is not set}"
NOTARY_PROFILE="${NOTARY_PROFILE:-perch-notary}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"

cd "$(dirname "$0")/.."

PLISTBUDDY=/usr/libexec/PlistBuddy
PRODUCT=Perch
BUNDLE_ID=tech.sugarhouse.Perch
OUT=.build/release-app
APP="$OUT/$PRODUCT.app"
ARCHS=(--arch arm64 --arch x86_64)

step() { printf '\n==> %s\n' "$*"; }

if [[ "$SIGN_ID" == "-" ]]; then
    echo "release needs a Developer ID: set LOCAL_SIGN_ID in local.mk" >&2
    exit 1
fi
if [[ "$ALLOW_DIRTY" != 1 && -n "$(git status --porcelain)" ]]; then
    echo "the working tree has changes; commit them first (or ALLOW_DIRTY=1)" >&2
    exit 1
fi

VERSION="$($PLISTBUDDY -c 'Print :CFBundleShortVersionString' Info.plist)"
# The commit count only grows on main, so each release's build number is
# larger than the last, which is what macOS and updaters compare.
BUILD="$(git rev-list --count HEAD)"
COMMIT="$(git rev-parse --short HEAD)"
ZIP="$OUT/$PRODUCT-$VERSION.zip"

step "Perch $VERSION ($BUILD, $COMMIT) with $(swift --version 2>/dev/null | head -1)"

step "Testing"
swift test

step "Building universal release from scratch"
rm -rf "$OUT" .build/out
swift build -c release "${ARCHS[@]}" --product "$PRODUCT"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$PRODUCT"
[[ "$(lipo -archs "$BIN")" == "x86_64 arm64" ]] || {
    echo "expected a universal binary, got: $(lipo -archs "$BIN")" >&2; exit 1; }

step "Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
cp -R Resources/ "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
$PLISTBUDDY -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
$PLISTBUDDY -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

step "Signing with $SIGN_ID"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
    --entitlements Perch.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"

step "Notarising (this usually takes a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$OUT/notarize.zip"

step "Stapling and checking Gatekeeper"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"

step "Packaging"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo
echo "Released $ZIP"
cat "$ZIP.sha256"
