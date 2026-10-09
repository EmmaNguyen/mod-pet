#!/bin/sh
# Builds Mochi Studio.app next to this script. Run it again after changing main.swift.
set -e
cd "$(dirname "$0")"
mkdir -p "Mochi Studio.app/Contents/MacOS"
cat > "Mochi Studio.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mochi Studio</string>
  <key>CFBundleIdentifier</key><string>local.claude-mods.mochi-studio</string>
  <key>CFBundleExecutable</key><string>Mochi Studio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
swiftc -O -parse-as-library -o "Mochi Studio.app/Contents/MacOS/Mochi Studio" main.swift
codesign --force --sign - "Mochi Studio.app"
echo "Built $(pwd)/Mochi Studio.app"
