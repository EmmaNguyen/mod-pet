#!/bin/sh
# Runs every Mochi test: the plugin's approval tests, Mochi Desktop's and Mochi Studio's logic tests, and a
# build of both apps. Prints ALL TESTS PASSED and exits 0 only if everything passes.
# Run it before merging dev into main: sh test.sh
set -e
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== Plugin (pet-mod) approval tests"
(cd pet-mod/tests && bun test approval.test.ts)

echo "== Mochi Desktop logic tests"
mkdir -p "$work/desktop"
awk '/^let app = NSApplication.shared/ { exit } { print }' mochi-desktop/main.swift > "$work/desktop/main.swift"
cat mochi-desktop/tests/DesktopTests.swift >> "$work/desktop/main.swift"
swiftc -o "$work/desktop/tests" "$work/desktop/main.swift" -framework AppKit 2>&1 | grep -E "error" && exit 1 || true
"$work/desktop/tests"

echo "== Mochi Studio logic tests"
mkdir -p "$work/studio"
awk '/^@main/ { exit } { print }' mochi-studio/main.swift > "$work/studio/main.swift"
cat mochi-studio/tests/StudioTests.swift >> "$work/studio/main.swift"
swiftc -o "$work/studio/tests" "$work/studio/main.swift" 2>&1 | grep -E "error" && exit 1 || true
"$work/studio/tests"

echo "== Builds"
swiftc -O -o "$work/MochiApp" mochi-desktop/main.swift -framework AppKit 2>&1 | grep -E "error" && exit 1 || true
test -x "$work/MochiApp" && echo "Mochi Desktop builds"
swiftc -O -parse-as-library -o "$work/StudioApp" mochi-studio/main.swift 2>&1 | grep -E "error" && exit 1 || true
test -x "$work/StudioApp" && echo "Mochi Studio builds"

echo "ALL TESTS PASSED"
