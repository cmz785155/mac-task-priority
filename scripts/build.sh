#!/bin/zsh
set -eu
cd "${0:A:h:h}"
APP="${1:-$PWD/dist/release/Mac能耗模式.app}"
if [[ -e "$APP" && ! -d "$APP" ]]; then
    echo "输出位置是文件或 Finder 替身，请指定新的应用路径：$0 /完整路径/Mac能耗模式.app" >&2
    exit 1
fi
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.1 -O -framework AppKit -framework IOKit Sources/main.swift Sources/Authorization.swift Sources/PowerSettings.swift -o "$APP/Contents/MacOS/MacPowerModes"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacPowerModes</string>
<key>CFBundleIdentifier</key><string>local.macpowermodes.app</string>
<key>CFBundleName</key><string>Mac能耗模式</string>
<key>CFBundleDisplayName</key><string>Mac能耗模式</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>15.1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
