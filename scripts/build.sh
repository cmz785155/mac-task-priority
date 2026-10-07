#!/bin/zsh
set -eu
cd "${0:A:h:h}"
APP="${1:-$PWD/dist/release/Mac任务优先级.app}"
if [[ -e "$APP" && ! -d "$APP" ]]; then
    echo "输出位置是文件或 Finder 替身，请指定新的应用路径：$0 /完整路径/Mac任务优先级.app" >&2
    exit 1
fi
mkdir -p "$APP/Contents/MacOS"
xcrun clang -O2 -Wall -Wextra -target arm64-apple-macos15.1 Sources/priority-helper.c -o "$APP/Contents/MacOS/priority-helper"
codesign --force --sign - "$APP/Contents/MacOS/priority-helper"
PROBE_DIR=$(/usr/bin/mktemp -d /tmp/mac-task-probe.XXXXXX)
trap '/bin/rm -rf "$PROBE_DIR"' EXIT
xcrun clang -O2 -Wall -Wextra -target arm64-apple-macos15.1 -c Sources/ProcessProbe.c -o "$PROBE_DIR/probe.o"
xcrun swiftc -import-objc-header Sources/ProcessProbe.h "$PROBE_DIR/probe.o" -swift-version 5 -target arm64-apple-macos15.1 -O -framework AppKit Sources/main.swift Sources/Authorization.swift Sources/TaskPriority.swift -o "$APP/Contents/MacOS/MacPowerModes"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacPowerModes</string>
<key>CFBundleIdentifier</key><string>local.macpowermodes.app</string>
<key>CFBundleName</key><string>Mac任务优先级</string>
<key>CFBundleDisplayName</key><string>Mac任务优先级</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.1</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>15.1</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
