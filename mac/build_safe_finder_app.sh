#!/bin/sh
# Build "Safe Finder.app" and put it in /Applications.
#
#   sh mac/build_safe_finder_app.sh              # build and install
#   sh mac/build_safe_finder_app.sh --no-install # just build, into mac/dist/
#
# Uses mac/.venv (the same one "Safe Finder.command" makes), adding PyInstaller to it; turns
# safe_finder_icon.png into the app icon; bundles the drive tools (relocate_folders.py, exfat_inspect.py,
# spare_folders.py) into the app's Contents/Resources so the "make spare folders" command Safe Finder
# shows works without the repo, plus airdrop_to_iphone.py and airdrop_helper.swift for "AirDrop to
# iPhone…" and thumb_helper.swift for video thumbnails (both helpers are compiled on first use with
# Xcode's swiftc); adds the privacy strings macOS
# shows when the app first opens Desktop,
# Documents, Downloads or an external drive; signs the app ad hoc (so those permissions stick) and
# copies it to /Applications, or ~/Applications when /Applications isn't writable.
#
# The app is a snapshot of the code — run this again after every "git pull". Settings, the staging
# folder and the transfer journal are shared with "Safe Finder.command".
set -eu
cd "$(dirname "$0")"

if [ "$(uname)" != "Darwin" ]; then
  echo "This builds a Mac app — run it on the Mac."; exit 1
fi
INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

# 1. The virtual environment, with PyInstaller.
if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c "import PySide6, numpy" 2>/dev/null; then
  echo "Setting up mac/.venv (once) …"
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet -r requirements.txt
fi
.venv/bin/python -c "import PyInstaller" 2>/dev/null || .venv/bin/pip install --quiet pyinstaller

# 2. The icon: one .icns from the 1024-px PNG.
rm -rf build/SafeFinder.iconset build/SafeFinder.icns
mkdir -p build/SafeFinder.iconset
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" safe_finder_icon.png --out "build/SafeFinder.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" safe_finder_icon.png --out "build/SafeFinder.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/SafeFinder.iconset -o build/SafeFinder.icns

# 3. The bundle.
VERSION="$(date +%Y.%m.%d)"
if command -v git >/dev/null 2>&1 && git rev-parse --short HEAD >/dev/null 2>&1; then
  VERSION="$VERSION ($(git rev-parse --short HEAD))"
fi
echo "Building Safe Finder.app $VERSION …"
rm -rf "dist/Safe Finder" "dist/Safe Finder.app"
.venv/bin/pyinstaller --noconfirm --clean --log-level WARN \
  --windowed --name "Safe Finder" \
  --icon "$PWD/build/SafeFinder.icns" \
  --osx-bundle-identifier com.photobrowser.safefinder \
  --add-data "$PWD/relocate_folders.py:." \
  --add-data "$PWD/exfat_inspect.py:." \
  --add-data "$PWD/spare_folders.py:." \
  --add-data "$PWD/airdrop_to_iphone.py:." \
  --add-data "$PWD/airdrop_helper.swift:." \
  --add-data "$PWD/thumb_helper.swift:." \
  --workpath build/pyinstaller --distpath dist --specpath build \
  safe_finder.py

APP="dist/Safe Finder.app"
PLIST="$APP/Contents/Info.plist"
plist_set() {   # key type value — Set, or Add when the key isn't there yet
  /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"
}
plist_set CFBundleShortVersionString string "$VERSION"
plist_set CFBundleVersion string "$(date +%Y%m%d%H%M)"
plist_set CFBundleDisplayName string "Safe Finder"
plist_set LSApplicationCategoryType string public.app-category.utilities
plist_set NSHumanReadableCopyright string "Photo Browser"
plist_set NSDesktopFolderUsageDescription string "Safe Finder shows the files on your Desktop so you can move them to the SSD."
plist_set NSDocumentsFolderUsageDescription string "Safe Finder shows the files in Documents so you can move them to the SSD."
plist_set NSDownloadsFolderUsageDescription string "Safe Finder shows the files in Downloads so you can move them to the SSD."
plist_set NSRemovableVolumesUsageDescription string "Safe Finder copies your photos and videos onto the external SSD."
plist_set NSNetworkVolumesUsageDescription string "Safe Finder can show files on network drives too."
plist_set NSAppleEventsUsageDescription string "Safe Finder asks Finder to move originals to the Trash after their copies are verified."

# Editing Info.plist breaks PyInstaller's signature, so sign again (ad hoc — no developer account needed).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(couldn't sign the app ad hoc — it still runs)"
echo "Built $APP"

# 4. Install.
if [ "$INSTALL" = 1 ]; then
  if pgrep -f "Safe Finder.app/Contents/MacOS/Safe Finder" >/dev/null 2>&1; then
    echo "Safe Finder is running — quit it, then run this again to install the new build (it's in $PWD/$APP)."
    exit 1
  fi
  DEST=/Applications
  if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
  fi
  rm -rf "$DEST/Safe Finder.app"
  ditto "$APP" "$DEST/Safe Finder.app"
  echo "Installed $DEST/Safe Finder.app — open it from Launchpad or Spotlight."
  echo "The first time, macOS asks whether Safe Finder may use Desktop, Documents, Downloads and external drives;"
  echo "say yes (System Settings ▸ Privacy & Security ▸ Files and Folders if you change your mind)."
fi
