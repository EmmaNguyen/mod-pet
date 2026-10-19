# Mochi: facts sheet

Every claim here is checked against the repo. Where the source is given, check it again before a claim goes into a post or article.

## Basics

- **Name:** Mochi
- **Tagline:** A pixel-art companion for Claude Code on macOS. (README.md, first lines)
- **What it does:** Mochi floats above your message box and shows the state of every Claude Code chat: working, needs your OK, ready, or blocked. (README.md, Features)
- **Approvals from her:** when a chat asks for permission, her card has Allow and Deny buttons. (README.md, Features)
- **Looks:** six skins, chosen from her right-click menu. Mochi Studio edits her body colour, eyes, accessory (none, bow, hat, or scarf), and name, with a live preview. (README.md; mochi-studio/main.swift)
- **Parts:** `pet-mod/` is the Claude Code plugin, `mochi-desktop/` is the floating macOS app, and `mochi-studio/` is the look editor. (README.md, "The project has two parts")

## Requirements and install

- macOS 13 or later. The Liquid Glass look needs macOS 26; earlier versions use a frosted style. (README.md, Requirements)
- Claude Code 2.1 or later, with the Claude desktop app. (README.md, Requirements)
- Xcode command line tools, to build the app. (README.md, Requirements)
- Install is a source build. There are no release builds yet, and the app is not notarised, so macOS may show a warning. (README.md roadmap; CLAUDE-SETUP.md)

## Privacy

- Mochi reads and writes files only in `~/.claude/mochi/` and Claude's own app folders. (README.md, Privacy)
- Mochi's own code makes no network requests. The usage check runs Claude's own `/usage` copy, which contacts Anthropic, the same as `/usage` does. (README.md, Privacy; code search found no URLs in app or plugin source)
- Mochi keeps a daily count in `~/.claude/mochi/days.json`, with no chat content. (README.md, "This week and diary")

## Project status

- Licence: MIT, copyright 2026 Emma Nguyen. (LICENSE)
- Status: work in progress. The README says parts are still changing and things may break. Say so in any post. (README.md banner)
- Built with Claude Code. Commit history has Co-Authored-By trailers for Claude. Say this plainly if asked.
- Maker: Emma Nguyen, working solo.

## Do not use yet

- "Anthropic announced mods on 1 October 2026." The README cites a single third-party report for this, and marks it as needing a check against Anthropic's documentation. Leave it out of press copy until it's checked.
- Any usage numbers, download counts, stars, or user counts. None are verified.
- "Notarised" or "signed". The app is ad-hoc signed and not notarised.
