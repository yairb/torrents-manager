#!/bin/bash
#
# Builds TorrentApp in Release, makes it self-contained, and installs it as the Mac's single
# canonical copy — the one that LaunchServices hands every magnet: link to.
#
# Why this exists rather than "just build it in Xcode": running the app out of DerivedData
# registers that DerivedData path with LaunchServices. Regenerating the .xcodeproj (which
# xcodegen does routinely) mints a *new* DerivedData folder, so copies accumulate. LaunchServices
# keys apps by path, not bundle ID, so it treats them as different apps and will happily run
# several at once — which is what makes a magnet click open a second instance. This script builds
# to a fixed path, installs exactly one bundle, and removes every other copy of it: unregistering
# alone doesn't last, because a bundle still sitting on disk gets registered again on the next
# rescan. Copies under DerivedData or ./build are deleted outright (they are build artifacts and
# rebuild on demand); anything elsewhere is unregistered and reported for you to deal with.
#
# Usage:
#   ./Scripts/install.sh                  # build and install to /Applications
#   ./Scripts/install.sh --no-launch      # ...but don't open the app afterwards
#   DESTINATION=/tmp/try ./Scripts/install.sh   # dry run: build + bundle, touch nothing system-wide

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="TorrentApp"
SCHEME="TorrentApp"
DESTINATION="${DESTINATION:-/Applications}"
LAUNCH_AFTER_INSTALL=1
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH_AFTER_INSTALL=0 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "Checking prerequisites"
# ---------------------------------------------------------------------------

command -v brew >/dev/null 2>&1 || die "Homebrew is required. Install it from https://brew.sh"
command -v xcodegen >/dev/null 2>&1 || die "xcodegen is required. Run: brew install xcodegen"
brew list --formula libtorrent-rasterbar >/dev/null 2>&1 \
  || die "libtorrent-rasterbar is required. Run: brew install libtorrent-rasterbar"

# xcodebuild refuses to run when xcode-select points at the Command Line Tools rather than a full
# Xcode. Fix it for this process only — changing it system-wide needs sudo, which is the user's call.
if [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    echo "xcode-select points at the Command Line Tools; using $DEVELOPER_DIR for this build."
    echo "To make that permanent: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  else
    die "Full Xcode is required (found only the Command Line Tools). Install Xcode, then run:
       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi
fi

# Homebrew lives at /opt/homebrew on Apple Silicon and /usr/local on Intel. project.yml hardcodes
# the Apple Silicon paths, so override them here instead of making the reader edit the file.
BREW_PREFIX="$(brew --prefix)"
echo "Homebrew prefix: $BREW_PREFIX"

# ---------------------------------------------------------------------------
step "Generating the Xcode project"
# ---------------------------------------------------------------------------

xcodegen generate

# ---------------------------------------------------------------------------
step "Building $APP_NAME (Release)"
# ---------------------------------------------------------------------------

# A fixed -derivedDataPath is the point: it stops a fresh DerivedData folder (and a fresh
# LaunchServices registration) being created every time the project is regenerated.
BUILD_DIR="$REPO_ROOT/build"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  HEADER_SEARCH_PATHS="$BREW_PREFIX/opt/libtorrent-rasterbar/include $BREW_PREFIX/opt/boost/include $BREW_PREFIX/opt/openssl@3/include" \
  LIBRARY_SEARCH_PATHS="$BREW_PREFIX/opt/libtorrent-rasterbar/lib $BREW_PREFIX/opt/openssl@3/lib $BREW_PREFIX/lib" \
  LD_RUNPATH_SEARCH_PATHS="@executable_path/../Frameworks $BREW_PREFIX/opt/libtorrent-rasterbar/lib $BREW_PREFIX/lib" \
  clean build

BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[[ -d "$BUILT_APP" ]] || die "build succeeded but $BUILT_APP is missing"

# ---------------------------------------------------------------------------
step "Vendoring Homebrew dylibs into the app bundle"
# ---------------------------------------------------------------------------

# Without this the installed app points at $BREW_PREFIX by absolute path and stops launching the
# day `brew upgrade` bumps libtorrent's soname or you remove the formula.
EXECUTABLE="$BUILT_APP/Contents/MacOS/$APP_NAME"
FRAMEWORKS="$BUILT_APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

# Every dependency of a Mach-O that lives under the Homebrew prefix. Note that a dylib's own
# LC_ID_DYLIB shows up here too; that's harmless, it just gets skipped as already-seen.
brew_deps() {
  otool -L "$1" | tail -n +2 | awk '{print $1}' | grep "^$BREW_PREFIX/" || true
}

# macOS ships bash 3.2, which has no associative arrays — a delimited string is the portable way
# to track what's already been copied.
bundled=":"
queue="$EXECUTABLE"

while [[ -n "$queue" ]]; do
  current="${queue%%$'\n'*}"
  if [[ "$queue" == *$'\n'* ]]; then queue="${queue#*$'\n'}"; else queue=""; fi

  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    base="$(basename "$dep")"
    case "$bundled" in *":$base:"*) continue ;; esac

    # `cp` follows the opt/ symlink through to the real file in the Cellar.
    cp -f "$dep" "$FRAMEWORKS/$base"
    chmod u+w "$FRAMEWORKS/$base"
    install_name_tool -id "@rpath/$base" "$FRAMEWORKS/$base"
    bundled="$bundled$base:"
    queue="${queue:+$queue$'\n'}$FRAMEWORKS/$base"
    echo "  bundled $base"
  done < <(brew_deps "$current")
done

# Second pass: repoint every load command at the bundled copies. This has to cover both the
# $BREW_PREFIX/opt/... symlink paths and the $BREW_PREFIX/Cellar/... real paths — libssl, for
# instance, references libcrypto through the Cellar path rather than the opt symlink.
for binary in "$EXECUTABLE" "$FRAMEWORKS"/*.dylib; do
  [[ -e "$binary" ]] || continue
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$binary"
  done < <(brew_deps "$binary")
done

remaining="$(brew_deps "$EXECUTABLE")"
[[ -z "$remaining" ]] || die "executable still references Homebrew paths:\n$remaining"

# ---------------------------------------------------------------------------
step "Re-signing"
# ---------------------------------------------------------------------------

# install_name_tool invalidates the signature Xcode applied. Sign nested code first, then the
# bundle — codesign --deep is deprecated and signs in the wrong order for this.
for dylib in "$FRAMEWORKS"/*.dylib; do
  [[ -e "$dylib" ]] || continue
  codesign --force --sign - "$dylib"
done
codesign --force --sign - "$BUILT_APP"
codesign --verify --strict "$BUILT_APP" || die "codesign verification failed"

# ---------------------------------------------------------------------------
step "Installing to $DESTINATION"
# ---------------------------------------------------------------------------

INSTALLED_APP="$DESTINATION/$APP_NAME.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quitting the running $APP_NAME…"
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.5
  done
  pgrep -x "$APP_NAME" >/dev/null 2>&1 && pkill -x "$APP_NAME" || true
fi

mkdir -p "$DESTINATION"
rm -rf "$INSTALLED_APP"
# ditto rather than cp -R: it preserves extended attributes and the code signature.
ditto "$BUILT_APP" "$INSTALLED_APP"
echo "Installed $INSTALLED_APP"

# Registration only makes sense for a real install; a DESTINATION override is a dry run.
if [[ "$DESTINATION" != "/Applications" ]]; then
  warn "DESTINATION is not /Applications — skipping LaunchServices registration and the default-handler step."
  echo "Done (dry run)."
  exit 0
fi

# ---------------------------------------------------------------------------
step "Removing every other copy of the app"
# ---------------------------------------------------------------------------

# This is the actual fix for "a magnet link opens a new instance". LaunchServices keys apps by
# path, not by bundle ID, so any other TorrentApp.app on disk is a *different app* as far as it is
# concerned — one it is happy to launch alongside the installed copy.
#
# Unregistering is not enough on its own: the bundle is still on disk, so LaunchServices registers
# it again the next time it rescans, and `xcodebuild` re-registers its own build product outright
# (it runs `lsregister -f -R -trusted` as a build phase). Copies that are plainly build artifacts
# are therefore deleted rather than just unregistered. Anything outside a build directory is only
# unregistered and reported, since it might be a copy you put there deliberately.

is_build_artifact() {
  case "$1" in
    "$HOME"/Library/Developer/Xcode/DerivedData/*) return 0 ;;
    "$REPO_ROOT"/build/*) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r stale; do
  [[ -n "$stale" ]] || continue
  [[ "$stale" == "$INSTALLED_APP" ]] && continue
  echo "  unregistering $stale"
  "$LSREGISTER" -u "$stale" >/dev/null 2>&1 || true
  if [[ -d "$stale" ]]; then
    if is_build_artifact "$stale"; then
      echo "  deleting build artifact  $stale"
      rm -rf "$stale"
    else
      warn "$stale is still on disk. Delete it, or macOS may register it again and open magnet
         links with it instead of $INSTALLED_APP."
    fi
  fi
done < <("$LSREGISTER" -dump 2>/dev/null | grep -oE "/[^ ]*$APP_NAME\.app" | sort -u)

# A build artifact that hasn't been registered yet is still a time bomb, so sweep the build
# directories as well rather than trusting the registration database to list everything.
while IFS= read -r artifact; do
  [[ -n "$artifact" ]] || continue
  echo "  deleting build artifact  $artifact"
  "$LSREGISTER" -u "$artifact" >/dev/null 2>&1 || true
  rm -rf "$artifact"
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" "$REPO_ROOT/build" \
              -maxdepth 6 -type d -name "$APP_NAME.app" -prune -print 2>/dev/null | sort -u || true)

"$LSREGISTER" -f "$INSTALLED_APP"
echo "Registered $INSTALLED_APP"

# ---------------------------------------------------------------------------
step "Setting $APP_NAME as the default magnet: handler"
# ---------------------------------------------------------------------------

# NSWorkspace.setDefaultApplication is the macOS 14+ replacement for the deprecated
# LSSetDefaultHandlerForURLScheme. macOS may show a consent prompt the first time.
SNIPPET="$(mktemp -t torrentapp-handler).swift"
cat > "$SNIPPET" <<'SWIFT_EOF'
import AppKit

guard let path = ProcessInfo.processInfo.environment["TORRENTAPP_PATH"] else {
    FileHandle.standardError.write(Data("TORRENTAPP_PATH not set\n".utf8))
    exit(1)
}
let semaphore = DispatchSemaphore(value: 0)
var failure: (any Error)?
NSWorkspace.shared.setDefaultApplication(
    at: URL(fileURLWithPath: path),
    toOpenURLsWithScheme: "magnet"
) { error in
    failure = error
    semaphore.signal()
}
semaphore.wait()
if let failure {
    FileHandle.standardError.write(Data("\(failure)\n".utf8))
    exit(1)
}
SWIFT_EOF

if TORRENTAPP_PATH="$INSTALLED_APP" swift "$SNIPPET"; then
  echo "magnet: links now open in $INSTALLED_APP"
else
  warn "could not set the default magnet: handler automatically.
       Set it by hand: right-click a .torrent file > Get Info > Open with > $APP_NAME > Change All,
       or click a magnet link and pick $APP_NAME when macOS asks."
fi
rm -f "$SNIPPET"

# ---------------------------------------------------------------------------
step "Done"
# ---------------------------------------------------------------------------

echo "Installed: $INSTALLED_APP"
echo "Registered copies of $APP_NAME.app now known to LaunchServices:"
"$LSREGISTER" -dump 2>/dev/null | grep -oE "/[^ ]*$APP_NAME\.app" | sort -u | sed 's/^/  /'

if [[ "$LAUNCH_AFTER_INSTALL" -eq 1 ]]; then
  open "$INSTALLED_APP"
fi
