#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Use the installed command-line toolchain when Xcode is not configured.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
mkdir -p build/ModuleCache
SDK_PATH="$(xcrun --show-sdk-path)"
swift build -c release --disable-sandbox --cache-path "$PWD/build/SwiftPMCache" --config-path "$PWD/build/SwiftPMConfig" --security-path "$PWD/build/SwiftPMSecurity" -Xswiftc -sdk -Xswiftc "$SDK_PATH" -Xcc -isysroot -Xcc "$SDK_PATH"
APP_PATH="$PWD/build/AmberFM.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/release/AmberFM "$APP_PATH/Contents/MacOS/AmberFM"
swift -module-cache-path "$PWD/build/ModuleCache" scripts/make-icon.swift "$PWD/build/AmberFM.iconset"
iconutil -c icns "$PWD/build/AmberFM.iconset" -o "$APP_PATH/Contents/Resources/AmberFM.icns"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Amber FM</string>
<key>CFBundleDisplayName</key><string>Amber FM</string>
<key>CFBundleIdentifier</key><string>local.amberfm.synth</string>
<key>CFBundleExecutable</key><string>AmberFM</string>
<key>CFBundleIconFile</key><string>AmberFM</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --force --sign - "$APP_PATH"
codesign --verify --strict "$APP_PATH"
test -x "$APP_PATH/Contents/MacOS/AmberFM"
echo "AMBER_APP_BUILD_PASS: $APP_PATH"
