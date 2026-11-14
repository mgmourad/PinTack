#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) Release app and packages it into a styled disk image
# at dist/PinTack-<version>.dmg.
#
# The app is ad-hoc signed and NOT notarized (no Developer ID yet, SPEC.md §15.3), so another Mac's
# Gatekeeper will block the first launch. The window's background says how to get past it, and the
# READ ME file spells out all three ways.
#
# Usage: scripts/make-dmg.sh [build-changelog.md]
#   The optional file is copied into the image beside the READ ME, as build-changelog.md: what
#   changed in THIS build, for the testers who get it.
set -euo pipefail
CHANGELOG_FILE="${1:-}"
[ -z "$CHANGELOG_FILE" ] || CHANGELOG_FILE="$(cd "$(dirname "$CHANGELOG_FILE")" && pwd)/$(basename "$CHANGELOG_FILE")"
cd "$(dirname "$0")/.."

APP=build/Release/PinTack.app
BACKGROUND=docs/assets/dmg-background.png
BACKGROUND2X=docs/assets/dmg-background@2x.png
VOLUME="PinTack"
WINDOW_W=660
WINDOW_H=596
ICON_SIZE=104

echo "── building universal Release ──"
xcodebuild -scheme PinTack -configuration Release SYMROOT="$PWD/build" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build | tail -1

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/PinTack-$VERSION.dmg"
STAGE=$(mktemp -d)
mkdir -p dist

echo "── staging ──"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$BACKGROUND" "$STAGE/.background/background.png"
[ -f "$BACKGROUND2X" ] && cp "$BACKGROUND2X" "$STAGE/.background/background@2x.png"

cat > "$STAGE/READ ME FIRST.txt" <<'EOF'
PinTack — a build for testers

1. Drag PinTack into Applications.

2. The first time you open it, macOS will say it "cannot be opened because the developer cannot be
   verified". That is not a problem with the app: this build is not yet notarized by Apple. Do any
   ONE of these:

   • Right-click PinTack in Applications, choose Open, then Open again.
   • Open it once, then go to System Settings > Privacy & Security, scroll down, and click
     "Open Anyway".
   • In Terminal:  xattr -dr com.apple.quarantine /Applications/PinTack.app

3. Your notes are ordinary Markdown files in ~/Documents/PinTack/, created on first launch.
   Point iCloud Drive, Dropbox or Syncthing at that folder if you want them synced.

Press ⌥⌘N for a new note and ⌥⌘/ to see every shortcut.

Needs macOS 14 (Sonoma) or newer. Runs on both Apple Silicon and Intel.
EOF

[ -z "$CHANGELOG_FILE" ] || cp "$CHANGELOG_FILE" "$STAGE/build-changelog.md"
# What a tester should know: it is a beta, it carries no warranty, keep a backup.
cp BETA-TERMS.md "$STAGE/BETA-TERMS.md"

# A runner has no Finder to script, so the window it would have styled is carried in instead: a
# .DS_Store captured once from a styled image (packaging/dmg/DS_Store). The background path, the icon
# size and every icon position are stored by name, and those names do not change between builds, so
# the same file lays out every image. Without this an automated release ships a plain folder.
if [ -n "${PINTACK_DMG_NO_STYLE:-}" ] && [ -f packaging/dmg/DS_Store ]; then
  cp packaging/dmg/DS_Store "$STAGE/.DS_Store"
  echo "   carrying the saved window layout (no Finder on this machine)"
fi

# A read/WRITE image first: Finder cannot lay out a window on a compressed read-only one.
rm -f "$DMG" dist/.pintack-rw.dmg
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ dist/.pintack-rw.dmg >/dev/null
rm -rf "$STAGE"

# A volume of the same name already mounted (an older PinTack.dmg someone forgot to eject) makes
# the new one mount as "PinTack 1" — and then `tell disk "PinTack"` styles the OLD one while this
# build silently ships with no layout at all. Eject any stale copy first.
for stale in /Volumes/"$VOLUME" /Volumes/"$VOLUME"\ *; do
  [ -d "$stale" ] || continue
  echo "   ejecting a stale volume already mounted at $stale"
  hdiutil detach "$stale" -force >/dev/null 2>&1 || true
done

echo "── laying out the window ──"
MOUNT=$(hdiutil attach dist/.pintack-rw.dmg -nobrowse -noautoopen | tail -1 | awk -F'\t' '{print $NF}')
sleep 1
# Talk to the volume that was ACTUALLY mounted, whatever it ended up being called.
MOUNTED_NAME=$(basename "$MOUNT")
[ "$MOUNTED_NAME" = "$VOLUME" ] || echo "   note: mounted as '$MOUNTED_NAME'"

# Finder is scripted here because window backgrounds, icon size and icon positions live in the
# volume's .DS_Store, which nothing else can write. If this is refused (Automation permission),
# the image is still perfectly usable — just laid out by Finder's defaults.
#
# PINTACK_DMG_NO_STYLE=1 skips the attempt entirely. A continuous-integration runner has no Finder
# session to ask, and a refusal there can HANG waiting for a permission dialog nobody will ever
# answer, rather than failing cleanly — so the build says up front that it is not going to try.
if [ -n "${PINTACK_DMG_NO_STYLE:-}" ]; then
  echo "   skipping the Finder layout (PINTACK_DMG_NO_STYLE)"
elif osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$MOUNTED_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, {200 + $WINDOW_W}, {140 + $WINDOW_H}}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 12
    -- A POSIX alias, not a colon-path file reference: the latter is refused with -10006.
    set background picture of opts to (POSIX file "$MOUNT/.background/background.png" as alias)
    set position of item "PinTack.app" of container window to {165, 215}
    set position of item "Applications" of container window to {495, 215}
    -- The documents in a row of their own under the app, in the strip added to the background for
    -- them. Anything left unplaced is dropped in the middle of the window by Finder, over the title:
    -- that is what an unpositioned BETA-TERMS.md did (2026-09-27).
    --
    -- The heights are measured, not guessed: WINDOW_H covers the title bar (29pt) and the Finder
    -- status bar (27pt, a per-user setting this script cannot turn off), leaving 540pt of content —
    -- exactly the background's height. The picture is drawn 40pt taller than that so it still fills
    -- the window on a Mac whose status bar is hidden; the surplus is plain gradient and is cropped.
    set position of item "READ ME FIRST.txt" of container window to {110, 452}
    if exists item "BETA-TERMS.md" of container window then set position of item "BETA-TERMS.md" of container window to {330, 452}
    if exists item "build-changelog.md" of container window then set position of item "build-changelog.md" of container window to {550, 452}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
then
  echo "   window styled"
else
  echo "   NOTE: Finder would not accept the layout (Automation permission?)."
  echo "   The disk image is still fine; it will just use Finder's default arrangement."
fi

# Finder writes .DS_Store when the window closes; detaching too soon loses the whole layout.
sleep 2
sync
hdiutil detach "$MOUNT" >/dev/null
sleep 1

echo "── compressing ──"
hdiutil convert dist/.pintack-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f dist/.pintack-rw.dmg

# The Release app must not stay in build/: LaunchServices would register it and Spotlight would
# list PinTack twice.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
rm -rf build/Release

hdiutil verify "$DMG" | tail -1

# Prove the styling actually shipped. Without this the image looks fine and opens plain.
CHECK=$(hdiutil attach "$DMG" -nobrowse -readonly | tail -1 | awk -F'\t' '{print $NF}')
if strings "$CHECK/.DS_Store" 2>/dev/null | grep -q "background.png"; then
  echo "   window layout and background: present"
else
  echo "   WARNING: the disk image has no stored layout — it will open as a plain folder."
fi
hdiutil detach "$CHECK" >/dev/null

ls -lh "$DMG"
