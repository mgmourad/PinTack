#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Release app and packs it into dist/PinTack-<version>.dmg.
# The app is ad-hoc signed, NOT notarized (no Developer ID yet, SPEC.md §14), so another Mac's Gatekeeper
# will block the first launch; the note inside the DMG tells the tester how to get past it.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -scheme PinTack -configuration Release SYMROOT="$PWD/build" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build | tail -1

APP=build/Release/PinTack.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
mkdir -p dist

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'EOF'
PinTack (test build)

1. Drag PinTack into Applications.
2. The first time, macOS will say it "cannot verify" the app, because this test build is not yet notarized by Apple.
   Do ONE of these:
   - Right-click PinTack in Applications, choose Open, then Open again.  (or)
   - Try to open it once, then System Settings > Privacy & Security > scroll down > "Open Anyway".  (or)
   - In Terminal:  xattr -dr com.apple.quarantine /Applications/PinTack.app
3. Your notes are plain Markdown files in ~/Documents/PinTack/ (created on first launch).

Needs macOS 14 (Sonoma) or newer.
EOF

rm -f "dist/PinTack-$VERSION.dmg"
hdiutil create -volname "PinTack" -srcfolder "$STAGE" -ov -format UDZO "dist/PinTack-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
# The Release app must not stay in build/: LaunchServices would register it and Spotlight would list PinTack twice.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" || true
rm -rf build/Release
hdiutil verify "dist/PinTack-$VERSION.dmg" | tail -1
ls -lh "dist/PinTack-$VERSION.dmg"
