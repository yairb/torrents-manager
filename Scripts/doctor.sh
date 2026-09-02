#!/bin/bash
#
# Read-only diagnosis of "why does a magnet link open a new instance?".
#
# Changes nothing. Run it and read the four sections: if section 1 lists more than one bundle, or
# section 2 shows a running process outside /Applications, or section 3 names a path that isn't
# the installed app, that is your answer — and ./Scripts/install.sh is the fix.

set -uo pipefail

APP_NAME="TorrentApp"
BUNDLE_ID="com.yairb.torrentapp"
INSTALLED_APP="/Applications/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

section "1. Bundles LaunchServices knows about (there should be exactly one)"
registered="$("$LSREGISTER" -dump 2>/dev/null | grep -oE "/[^ ]*$APP_NAME\.app" | sort -u)"
if [[ -z "$registered" ]]; then
  echo "  (none — the app has never been registered)"
else
  echo "$registered" | sed 's/^/  /'
fi

section "2. Bundles actually on disk"
{
  [[ -d "$INSTALLED_APP" ]] && echo "$INSTALLED_APP"
  find "$HOME/Library/Developer/Xcode/DerivedData" "$HOME/Desktop" "$HOME/Downloads" \
       -maxdepth 6 -type d -name "$APP_NAME.app" -prune -print 2>/dev/null
} | sort -u | sed 's/^/  /'

section "3. Running processes (more than one line is the bug)"
running="$(pgrep -x "$APP_NAME" 2>/dev/null)"
if [[ -z "$running" ]]; then
  echo "  (not running)"
else
  for pid in $running; do
    printf '  pid %s  %s\n' "$pid" "$(ps -o comm= -p "$pid" 2>/dev/null)"
  done
fi

section "4. Default handler for magnet: links"
defaults read com.apple.LaunchServices/com.apple.launchservices.secure LSHandlers 2>/dev/null \
  | grep -A3 'LSHandlerURLScheme = magnet' \
  | sed 's/^/  /' \
  || echo "  (no explicit default recorded — macOS is picking one for you)"

section "5. Is the installed app self-contained?"
if [[ -d "$INSTALLED_APP" ]]; then
  brewed="$(otool -L "$INSTALLED_APP/Contents/MacOS/$APP_NAME" 2>/dev/null | grep -cE '/(opt/homebrew|usr/local)/')"
  if [[ "$brewed" -gt 0 ]]; then
    echo "  NO — $brewed load command(s) still point into Homebrew. A 'brew upgrade' will break it."
  else
    echo "  yes — all non-system libraries are @rpath references inside the bundle"
  fi
  codesign --verify --strict "$INSTALLED_APP" 2>&1 | sed 's/^/  /' || true
  echo "  signature: $(codesign --verify --strict "$INSTALLED_APP" >/dev/null 2>&1 && echo valid || echo INVALID)"
else
  echo "  $INSTALLED_APP is not installed"
fi

printf '\n'
echo "Bundle ID checked: $BUNDLE_ID"
echo "Fix duplicates with: ./Scripts/install.sh"
