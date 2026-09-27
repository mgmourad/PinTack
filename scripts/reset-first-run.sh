#!/usr/bin/env bash
# Puts this Mac back to the state a brand-new user's Mac is in, so the next launch is a REAL first
# run: the greeting card, the welcome note, default settings, no stacks, no remembered approvals.
#
# Nothing is deleted. Everything PinTack has written is MOVED into one dated folder, so a run can be
# undone by moving it back. The app's own copy in /Applications is left alone: install the new build
# the way you always do, then run this before launching it.
#
# Usage: scripts/reset-first-run.sh [--dry-run] [--keep-vault] [--yes]
#   --dry-run     say what would move, move nothing
#   --keep-vault  leave the notes alone and reset only the "once" markers, settings and approvals
#   --yes         do not ask first
set -euo pipefail

BUNDLE_ID="io.cymentix.pintack"
DRY=0; KEEP_VAULT=0; ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --keep-vault) KEEP_VAULT=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) echo "unknown option: $arg"; exit 2 ;;
  esac
done

# The vault is wherever Settings last pointed it, not always ~/Documents/PinTack.
VAULT="$(defaults read "$BUNDLE_ID" vaultPath 2>/dev/null || true)"
[ -n "$VAULT" ] || VAULT="$HOME/Documents/PinTack"

ARCHIVE="$HOME/Desktop/PinTack-reset-$(date +%Y%m%d-%H%M%S)"

# What the app writes outside its own bundle, and outside the vault.
OUTSIDE_VAULT=(
  "$HOME/Library/Application Support/PinTack"                      # trust.key: the per-Mac signing secret for plugin approvals
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"                     # vault path, window bits macOS stores for us
  "$HOME/Library/WebKit/$BUNDLE_ID"                                # the editor's web view storage
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
)
# With the notes kept, only the parts that make a launch "not the first one" go.
INSIDE_VAULT=(
  "$VAULT/.pintack/onboarded"        # the greeting card, shown once
  "$VAULT/.pintack/welcomed"         # the welcome note, written once
  "$VAULT/.pintack/settings.json"    # every preference you have changed
  "$VAULT/.pintack/hotkeys.json"     # rebound shortcuts
  "$VAULT/.pintack/stacks.json"      # the piles on your desk
  "$VAULT/.pintack/trust.json"       # approved Runner commands
  "$VAULT/.pintack/linkpreviews.json"
  "$VAULT/.pintack/index.sqlite"     # the search index, rebuilt on launch
  "$VAULT/.pintack/stack-clicks.log"
)
if [ "$KEEP_VAULT" -eq 1 ]; then
  ITEMS=("${INSIDE_VAULT[@]}" "${OUTSIDE_VAULT[@]}")
else
  ITEMS=("$VAULT" "${OUTSIDE_VAULT[@]}")
fi

echo "PinTack first-run reset"
echo "  vault:   $VAULT"
echo "  archive: $ARCHIVE"
echo
present=()
for item in "${ITEMS[@]}"; do
  if [ -e "$item" ]; then
    size=$(du -sh "$item" 2>/dev/null | cut -f1 || echo "?")
    printf '  move  %-6s %s\n' "$size" "$item"
    present+=("$item")
  else
    printf '  gone         %s\n' "$item"
  fi
done
echo

if [ "${#present[@]}" -eq 0 ]; then
  echo "Nothing to move: this Mac already looks like a new one."
  exit 0
fi
if [ "$DRY" -eq 1 ]; then
  echo "Dry run: nothing was moved."
  exit 0
fi
if [ "$ASSUME_YES" -eq 0 ]; then
  printf 'Move these into %s? [y/N] ' "$ARCHIVE"
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "Nothing was moved."; exit 1 ;; esac
fi

# PinTack must not be running, or it writes its state back out as it quits.
if pgrep -x PinTack >/dev/null 2>&1; then
  echo "── quitting PinTack ──"
  osascript -e 'tell application "PinTack" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x PinTack >/dev/null 2>&1 || break; sleep 0.5; done
  pgrep -x PinTack >/dev/null 2>&1 && { echo "PinTack is still running; quit it and try again."; exit 1; }
fi

mkdir -p "$ARCHIVE"
for item in "${present[@]}"; do
  # Named for where it came from, not just its basename: three of these are called "PinTack", and
  # an archive of PinTack, PinTack-2, PinTack-3 tells you nothing when you come to put it back.
  label="${item#"$HOME"/}"
  dest="$ARCHIVE/${label//\//_}"
  n=2
  while [ -e "$dest" ]; do dest="$ARCHIVE/${label//\//_}-$n"; n=$((n + 1)); done
  mv "$item" "$dest"
  echo "  moved $item"
done

# macOS caches preferences in memory; without this the old plist can come back.
defaults read "$BUNDLE_ID" >/dev/null 2>&1 && defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
killall cfprefsd >/dev/null 2>&1 || true

echo
echo "Done. Everything is in $ARCHIVE — move it back to undo this."
echo
echo "Two things this cannot reset, because macOS keeps them by bundle identifier:"
echo "  • Notification permission. If you have already allowed (or refused) PinTack's reminders,"
echo "    that answer stands and the permission sheet will not appear again."
echo "  • Open at login. If you switched it on, macOS still has it: System Settings →"
echo "    General → Login Items, or switch it off in PinTack's Settings before resetting."
echo
echo "Now launch the new build. You should get the greeting card and one welcome note."
