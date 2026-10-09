# Set up Mochi (instructions for Claude)

You are setting up a Claude Code plugin and a macOS app for the user. Follow these steps in order. Stop and ask the user if a step fails or if anything here doesn't match their Mac.

## 1. Check the requirements

- Run `sw_vers -productVersion`. The Mac must be macOS 13 or later. The Liquid Glass look needs macOS 26; if the Mac is older, it still works with a frosted look.
- Run `xcrun --find swiftc`. If it fails, tell the user to run `xcode-select --install` and come back.

## 2. Install the Mochi app

1. Copy this folder's `mochi-desktop/` to `~/Documents/Claude Mods/Mochi Desktop/`. Create the folders if they don't exist.
2. In that folder run `sh build.sh`. It should print `Built ... Mochi.app`.
3. Open it once with `open "$HOME/Documents/Claude Mods/Mochi Desktop/Mochi.app"`. Mochi appears in the bottom-right corner of the screen. macOS may ask whether Mochi can send notifications; the user should allow it.
4. Check it runs: `pgrep -lf "Mochi.app/Contents/MacOS/Mochi"` should show one process.

## 3. Install the Claude Code plugin

This folder is a plugin marketplace. From a Claude Code chat, the user types:

    /plugin marketplace add <path to this folder>

Then install it:

    /plugin install pet-mod@mochi

Choose the **user** scope when asked. If the user has published this to GitHub, they can use `/plugin install pet-mod --marketplace <owner>/<repo>` instead.

## 4. Turn on hot reloading (optional, for editing)

If the user wants to change Mochi, ask them to enable hot reloading when Claude Code offers it. Otherwise they must run `/reload-plugins` after each change.

## 5. Check it works

1. Start a new Claude Code chat. Mochi should already be running. If not, run `open -g -b local.claude-mods.mochi`.
2. Send any message. Mochi should show "Working", then "Ready" when Claude replies, and a card should appear beside her.
3. Click Mochi. The list of chats should open.
4. Click the usage label under her. It should show "Checking your usage…" and then both limits.

If the usage check fails, the Claude app's copy of the command-line tool must be installed (it lives under `~/Library/Application Support/Claude/claude-code/`). Tell the user.

## Tests

To check the plugin: `claude plugin test <path to pet-mod>`. All tests should pass.

## Things you may need to change

- `mochi-desktop/main.swift` finds the plugin's data in `~/.claude/mochi/`. Don't change that unless the user asks.
- The fallback that reopens Mochi from `~/Documents/Claude Mods/Mochi Desktop/` is in `pet-mod/hooks/register.ts`. Change the path there if the user puts the app somewhere else.
