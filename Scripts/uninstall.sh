#!/bin/bash
#
# Removes TorrentApp from the Mac: quits it, deletes every copy of the bundle, and clears its
# LaunchServices registrations so magnet: links stop pointing at it.
#
# Downloaded files are never touched. The app's own state (session, settings, torrent list) lives
# in ~/Library/Application Support/TorrentApp and is kept unless you pass --purge-data.
#
# Usage:
#   ./Scripts/uninstall.sh                # remove the app, keep its data
#   ./Scripts/uninstall.sh --purge-data   # ...and delete ~/Library/Application Support/TorrentApp
#   ./Scripts/uninstall.sh --yes          # don't ask for confirmation

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="TorrentApp"
INSTALLED_APP="/Applications/$APP_NAME.app"
SUPPORT_DIR="$HOME/Library/Application Support/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
PURGE_DATA=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --purge-data) PURGE_DATA=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# Collect everything up front so the confirmation prompt can show exactly what will go.
targets=()
[[ -d "$INSTALLED_APP" ]] && targets+=("$INSTALLED_APP")
while IFS= read -r found; do
  [[ -n "$found" ]] || continue
  [[ "$found" == "$INSTALLED_APP" ]] && continue
  targets+=("$found")
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" "$REPO_ROOT/build" \
              -maxdepth 6 -type d -name "$APP_NAME.app" -prune -print 2>/dev/null | sort -u || true)

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "No $APP_NAME.app found in /Applications, DerivedData or $REPO_ROOT/build."
else
  echo "These bundles will be deleted:"
  printf '  %s\n' "${targets[@]}"
fi
if [[ "$PURGE_DATA" -eq 1 ]] && [[ -d "$SUPPORT_DIR" ]]; then
  echo "This directory will be deleted (settings, torrent list, resume data):"
  echo "  $SUPPORT_DIR"
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  printf '\nProceed? [y/N] '
  read -r reply
  [[ "$reply" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

step "Quitting $APP_NAME"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.5
  done
  pgrep -x "$APP_NAME" >/dev/null 2>&1 && pkill -x "$APP_NAME" || true
  echo "Quit."
else
  echo "Not running."
fi

step "Clearing LaunchServices registrations"
# Unregister by path, including paths whose bundle is already gone — a registration outlives the
# bundle it points at, and a stale one is what makes magnet: links behave strangely afterwards.
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  echo "  unregistering $path"
  "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
done < <("$LSREGISTER" -dump 2>/dev/null | grep -oE "/[^ ]*$APP_NAME\.app" | sort -u)

step "Deleting bundles"
for target in ${targets[@]+"${targets[@]}"}; do
  echo "  rm -rf $target"
  rm -rf "$target"
done

if [[ "$PURGE_DATA" -eq 1 ]]; then
  step "Deleting application support data"
  rm -rf "$SUPPORT_DIR"
  echo "  removed $SUPPORT_DIR"
else
  printf '\nKept %s — pass --purge-data to remove it too.\n' "$SUPPORT_DIR"
fi

step "Done"
echo "macOS will now offer magnet: links to whatever other torrent client is installed."
echo "Downloaded files were not touched."
