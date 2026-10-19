#!/bin/sh
# Renders the README screenshots into media/screenshots/ from the app's real views, with made-up chats.
# Nothing is captured from the screen and nothing is read from ~/.claude/mochi, so no private chat names can leak.
# Run it after changing how Mochi looks: sh media/snapshots.sh
set -e
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Mochi Desktop: main.swift without its last lines, which start the app, plus the renderer (the trick test.sh uses)
mkdir -p "$work/desktop"
awk '/^let app = NSApplication.shared/ { exit } { print }' mochi-desktop/main.swift > "$work/desktop/main.swift"
cat media/snapshots/Snapshots.swift >> "$work/desktop/main.swift"
swiftc -o "$work/desktop/snapshots" "$work/desktop/main.swift" -framework AppKit 2>&1 | grep -E "error" && exit 1 || true
"$work/desktop/snapshots" media/screenshots

# Mochi Studio: the same, cut before @main
mkdir -p "$work/studio"
# (Studio reads its look from the home folder, so in this copy only, home comes from $HOME, which is set below)
awk '/^@main/ { exit } { print }' mochi-studio/main.swift \
    | sed 's#FileManager.default.homeDirectoryForCurrentUser#URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())#' \
    > "$work/studio/main.swift"
cat media/snapshots/StudioSnapshot.swift >> "$work/studio/main.swift"
swiftc -o "$work/studio/snapshot" "$work/studio/main.swift" 2>&1 | grep -E "error" && exit 1 || true
# Studio opens with the saved look, so give it a sample one in a pretend home folder
mkdir -p "$work/home/.claude/mochi"
echo '{"body":"F4A259","accessory":"bow","eyes":"round","name":"Mochi","speed":1}' > "$work/home/.claude/mochi/look.json"
HOME="$work/home" "$work/studio/snapshot" media/screenshots/11-studio.png
