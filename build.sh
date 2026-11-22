#!/bin/sh
# Builds TrackBASIC.app (Apple Silicon and Intel) from Sources/.
#
#   ./build.sh          build TrackBASIC.app
#   ./build.sh run      build it and open it
set -e
cd "$(dirname "$0")"

[ "$(uname -s)" = "Darwin" ] || { echo "TrackBASIC builds on macOS only." >&2; exit 1; }
{ xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; } || {
    echo "Swift isn't installed. Run: xcode-select --install" >&2; exit 1; }

mkdir -p build
echo "building for Apple Silicon…"
swiftc -O -swift-version 5 -target arm64-apple-macos13 Sources/*.swift -o build/TrackBASIC-arm64
echo "building for Intel…"
swiftc -O -swift-version 5 -target x86_64-apple-macos13 Sources/*.swift -o build/TrackBASIC-x86_64

app=TrackBASIC.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Examples"
lipo -create build/TrackBASIC-arm64 build/TrackBASIC-x86_64 -output "$app/Contents/MacOS/TrackBASIC"
cp Info.plist "$app/Contents/Info.plist"
cp Examples/*.BAS "$app/Contents/Resources/Examples/"
codesign -s - -f --deep "$app" 2>/dev/null
echo "built $app"

[ "$1" = "run" ] && open "$app"
exit 0
