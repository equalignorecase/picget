#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:-${VERSION:-0.1.0}}"
VERSION="${VERSION#v}"
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
app="$PWD/build/Picget.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Picget.icns "$app/Contents/Resources/"
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" -target arm64-apple-macos14.0 \
  -strict-concurrency=complete -O -whole-module-optimization -g \
  Picget/*.swift -o "$app/Contents/MacOS/Picget"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleExecutable</key><string>Picget</string>
<key>CFBundleIdentifier</key><string>app.picget.desktop</string>
<key>CFBundleIconFile</key><string>Picget.icns</string>
<key>CFBundleName</key><string>Picget</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
