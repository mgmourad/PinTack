#!/usr/bin/env bash
# Stamps a built disk image's version and checksum into the Homebrew cask.
#
#   scripts/make-homebrew-cask.sh dist/PinTack-0.1.0.dmg [output.rb]
#
# Prints the finished cask, and writes it to the output path if one is given. Copy it into your
# tap's Casks/ directory (docs/HOMEBREW.md explains the tap, and the notarization it waits on).
set -euo pipefail
cd "$(dirname "$0")/.."
DMG="${1:-}"
[ -f "$DMG" ] || { echo "usage: scripts/make-homebrew-cask.sh <disk image> [output.rb]" >&2; exit 2; }

# The version comes from the app inside the image, not from the filename: a renamed file must not be
# able to publish a cask that points at a different build.
MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly -noautoopen | tail -1 | awk -F'\t' '{print $NF}')
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MOUNT/PinTack.app/Contents/Info.plist")
SIGNED=$(codesign -dv "$MOUNT/PinTack.app" 2>&1 | grep -c "Authority=Developer ID" || true)
NOTARIZED=$(spctl -a -t exec -vv "$MOUNT/PinTack.app" 2>&1 | grep -c "accepted" || true)
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
trap - EXIT

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
CASK=$(sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
           -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" packaging/homebrew/pintack.rb)

echo "$CASK"
if [ -n "${2:-}" ]; then
  printf '%s\n' "$CASK" > "$2"
  echo "── written to $2" >&2
fi

echo >&2
echo "── version $VERSION, sha256 $SHA" >&2
# Homebrew quarantines what it downloads and no longer has a --no-quarantine escape hatch, so an
# un-notarized build installs and then refuses to open. Say so here rather than let it be found by
# whoever runs brew install first.
if [ "$SIGNED" -eq 0 ] || [ "$NOTARIZED" -eq 0 ]; then
  echo "── WARNING: this build is not signed with a Developer ID and/or not notarized." >&2
  echo "   Homebrew quarantines its downloads, so Gatekeeper will block the first launch." >&2
  echo "   Publish the cask only once 'spctl -a -t exec -vv' accepts the app (docs/HOMEBREW.md)." >&2
else
  echo "── signed and notarized: ready to publish." >&2
fi
