#!/bin/sh
# Install a freshly built Ghostty macOS app as "pcode" into a versioned bundle
# under builds/ and point builds/current at it. Installing into a new versioned
# path avoids overwriting a running bundle, which causes macOS to kill the
# running process when code signature pages no longer match.
#
# Usage:
#   scripts/install-macos.sh          # package macos/build/ReleaseLocal/Ghostty.app
#   scripts/install-macos.sh --build  # run `zig build -Doptimize=ReleaseFast` first
#
# Launch:
#   builds/current/Contents/MacOS/ghostty
set -eu

cd "$(dirname "$0")/.."

if [ "${1:-}" = "--build" ]; then
    zig build -Doptimize=ReleaseFast
fi

src="${SRC_APP:-macos/build/ReleaseLocal/Ghostty.app}"
if [ ! -d "$src" ]; then
    echo "error: $src not found; run 'zig build -Doptimize=ReleaseFast' or pass --build" >&2
    exit 1
fi

name="${APP_NAME:-pcode}"
bundle_id="${BUNDLE_ID:-com.pcode.terminal}"

rev=$(git rev-parse --short HEAD)
if ! git diff --quiet HEAD -- src; then
    rev="$rev-dirty-$(date +%H%M%S)"
fi

dest="builds/${name}-${rev}.app"
tmp="${dest}.tmp"

trash() {
    if [ -e "$1" ]; then
        mv "$1" "$HOME/.Trash/$(basename "$1").$(date +%s)"
    fi
}

mkdir -p builds
trash "$tmp"
cp -R "$src" "$tmp"

plist="$tmp/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $name" "$plist"

codesign --force --deep --sign - "$tmp" >/dev/null 2>&1
codesign --verify "$tmp"

trash "$dest"
mv "$tmp" "$dest"
ln -sfn "$(basename "$dest")" builds/current

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" || true

echo "installed $dest (builds/current -> $(basename "$dest"))"
