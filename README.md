# TorrentApp

A native macOS BitTorrent client built with SwiftUI, backed by [libtorrent-rasterbar](https://www.libtorrent.org) for the actual protocol work.

Add magnet links or `.torrent` files, manage multiple simultaneous downloads with a configurable queue, pause/resume/remove, rename files, set per-file priority, and move a torrent's storage — all from a modern SwiftUI interface.

This project is built and run from source (via Xcode or `xcodebuild`); it is not distributed as a signed/notarized `.app` or through the Mac App Store.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (Command Line Tools must be installed too)
- [Homebrew](https://brew.sh)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — generates the `.xcodeproj` from [`project.yml`](project.yml)
- [libtorrent-rasterbar](https://www.libtorrent.org) — the BitTorrent engine, installed via Homebrew

> **Apple Silicon vs. Intel:** [`project.yml`](project.yml) hardcodes Homebrew's Apple Silicon prefix (`/opt/homebrew`) in its header/library search paths. On an Intel Mac, Homebrew installs under `/usr/local` instead — update `HEADER_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS`, and `LD_RUNPATH_SEARCH_PATHS` in `project.yml` accordingly before generating the project.

## Setup

1. Install Homebrew if you don't already have it: <https://brew.sh>

2. Install the build tools and the torrent engine:

   ```sh
   brew install xcodegen libtorrent-rasterbar
   ```

   This pulls in `boost` and `openssl@3` as dependencies, which the project also links against.

3. Generate the Xcode project from `project.yml`:

   ```sh
   xcodegen generate
   ```

   The `.xcodeproj` is generated, not checked into git — re-run this command any time `project.yml` changes, or after adding/removing source files (see [Development notes](#development-notes)).

## Install

This is how to get a real, permanently installed app — the one macOS hands every magnet link to.
For hacking on the code, see [Build & run (development)](#build--run-development) below instead.

### Prerequisites on the target Mac

- macOS 14 (Sonoma) or later
- **Full Xcode**, not just the Command Line Tools (`xcodebuild` refuses to run without it)
- `brew install xcodegen libtorrent-rasterbar`

### Install

```sh
./Scripts/install.sh
```

That's the whole thing. It:

1. Checks the prerequisites above and works around an `xcode-select` that points at the Command Line Tools.
2. Reads `brew --prefix`, so it works on both Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`) without editing `project.yml`.
3. Regenerates the Xcode project and builds Release into `./build` — a *fixed* path, which matters (see below).
4. Copies libtorrent-rasterbar, libssl, and libcrypto into `TorrentApp.app/Contents/Frameworks` and rewrites the load commands to `@rpath`, so the installed app keeps working after a `brew upgrade` that bumps libtorrent's version.
5. Re-signs the bundle ad-hoc (rewriting load commands invalidates the signature).
6. Quits any running copy and installs to `/Applications/TorrentApp.app`.
7. **Unregisters every other copy of the app from LaunchServices** and registers the installed one.
8. Sets TorrentApp as the default `magnet:` handler.

Expect two things afterwards: macOS may show a consent prompt when the default handler is set, and the
app now stays in the Dock after you close its window — it keeps downloading and seeding, and a magnet
click brings that same instance back rather than starting a new one.

Useful flags:

```sh
./Scripts/install.sh --no-launch          # install but don't open the app
DESTINATION=/tmp/try ./Scripts/install.sh # dry run: build and bundle, touch nothing system-wide
```

### Why step 7 matters

LaunchServices identifies applications by **path**, not by bundle identifier. Every copy of
`TorrentApp.app` it knows about is a separate app to it, and it will happily run several at once — so a
magnet link can open a *second* instance while the first is already running, with both fighting over the
same libtorrent session and Application Support directory.

Copies accumulate easily: `xcodebuild` registers its own build product as a build phase, and every
`xcodegen generate` can mint a fresh DerivedData folder. Building to a fixed `./build` path and
unregistering everything else is what keeps exactly one copy in play. Check at any time with:

```sh
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -dump | grep -oE '/[^ ]*TorrentApp\.app' | sort -u
```

After a clean install that should print `/Applications/TorrentApp.app` and nothing else.

### Updating

Re-run `./Scripts/install.sh`. It quits the running copy and replaces the installed bundle in place.

### Uninstalling

```sh
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -u /Applications/TorrentApp.app
rm -rf /Applications/TorrentApp.app
rm -rf ~/"Library/Application Support/TorrentApp"    # session state and settings; leaves downloads alone
```

The `lsregister -u` matters — without it macOS keeps offering a deleted app as a `magnet:` handler.

## Build & run (development)

> **Running from DerivedData registers that path with LaunchServices.** Doing it while an installed
> copy exists in `/Applications` is exactly what produces two instances competing for magnet links.
> Re-run `./Scripts/install.sh` afterwards to clean the stale registrations back up.

> If `xcodebuild` fails with *"requires Xcode, but active developer directory is a command line tools
> instance"*, either prefix the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
> or fix it permanently with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

### Option A — Xcode

```sh
open TorrentApp.xcodeproj
```

Select the **TorrentApp** scheme and press **⌘R**.

### Option B — command line

```sh
xcodebuild -project TorrentApp.xcodeproj -scheme TorrentApp -configuration Debug build
```

Then launch the built app from DerivedData, e.g.:

```sh
open "$(xcodebuild -project TorrentApp.xcodeproj -scheme TorrentApp -configuration Debug -showBuildSettings | awk -F'= ' '/ TARGET_BUILD_DIR /{print $2; exit}')/TorrentApp.app"
```

The app is unsigned (ad-hoc "Sign to Run Locally") and not notarized, which is expected for a from-source build — macOS will only complain via Gatekeeper if you try to distribute the built `.app` to someone else.

## Development notes

- **Source of truth is `project.yml`**, not the `.xcodeproj` — the project file is regenerated by XcodeGen and is gitignored. Run `xcodegen generate` after pulling changes that touch `project.yml`, and after adding, removing, or renaming any source file (XcodeGen's file list is a directory scan, not tracked incrementally).
- **Torrent engine bridge**: libtorrent-rasterbar is a C++ library; Swift talks to it through a thin Objective-C++ bridge (`Sources/Bridge/LTSession.h` / `.mm`), imported via a bridging header. All libtorrent/C++ types are confined to the `.mm` file — the header stays pure Objective-C so it can be imported directly into Swift.
- **App data**: session state (resume data, DHT cache, etc.) lives under `~/Library/Application Support/TorrentApp/`. Deleting that folder resets the engine's local state without touching downloaded files.
- **Single architecture only**: `project.yml` pins `ARCHS` to the host architecture. Homebrew ships single-arch dylibs, so a universal (arm64 + x86_64) build cannot link — Release would otherwise default to both and fail.

## Project structure

```
TorrentApp/
├── project.yml                  # XcodeGen project spec (source of truth)
├── Scripts/
│   └── install.sh               # Release build -> self-contained app -> /Applications
├── Resources/
│   └── Assets.xcassets/         # App icon, accent color
└── Sources/
    ├── App/                     # App entry point, Info.plist
    ├── Bridge/                  # Objective-C++ bridge to libtorrent-rasterbar
    ├── Engine/                  # TorrentEngine protocol + Fake/Real implementations
    ├── DownloadManager/         # Actor coordinating torrents, queueing, persistence
    ├── Models/                  # Torrent, AppSettings, etc.
    ├── Persistence/             # PersistenceStore protocol + JSON-backed implementation
    ├── Settings/                # SettingsManager
    ├── ViewModels/              # @Observable view models
    └── Views/                   # SwiftUI views (main window, torrent list/detail, settings)
```
