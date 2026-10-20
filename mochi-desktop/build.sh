#!/bin/sh
# Builds Mochi.app next to this script. Run it again after changing main.swift.
set -e
cd "$(dirname "$0")"

mkdir -p Mochi.app/Contents/MacOS
cat > Mochi.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mochi</string>
  <key>CFBundleIdentifier</key><string>local.claude-mods.mochi</string>
  <key>CFBundleExecutable</key><string>Mochi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Mochi</string><key>CFBundleURLSchemes</key><array><string>mochi</string></array></dict></array>
  <key>NSMicrophoneUsageDescription</key><string>Mochi listens when you press the microphone, to write your note.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Mochi turns what you say into text for your note.</string>
</dict>
</plist>
PLIST

swiftc -O -o Mochi.app/Contents/MacOS/Mochi main.swift -framework AppKit
codesign --force --sign - Mochi.app
echo "Built $(pwd)/Mochi.app"
