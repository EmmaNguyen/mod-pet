# Mochi

A pixel-art cat for Claude. She sits above your message box in Claude Code, floats on your Mac, and tells you what every Claude chat is doing:

- **Status:** working, needs your OK, ready, or blocked, with a badge and colours.
- **Notifications:** Liquid Glass cards beside her for finished work, questions, and tool approvals, with a sound when a chat needs you.
- **Click her** to see every chat and its latest news. Click a line to jump to that chat in Claude.
- **Six skins:** classic orange, midnight black, snow white, tuxedo, mint, and lavender galaxy. Pick one from her right-click menu under **Skin**.
- **Plan usage:** a label under her shows your 5-hour and weekly limits, and clicking it asks Claude for the exact numbers, the same as `/usage`. When you run out, she shows when you can continue.

Two parts work together:

| Part | What it is |
| --- | --- |
| `pet-mod/` | A Claude Code plugin. It tells Mochi what each chat is doing. |
| `mochi-desktop/` | A small macOS app that shows Mochi on your screen. |

## Setting it up

The easiest way is to open Claude Code and say:

> Follow CLAUDE-SETUP.md in this folder to set up Mochi.

Or follow the steps by hand in [CLAUDE-SETUP.md](CLAUDE-SETUP.md).

## Requirements

- macOS 13 or later (the Liquid Glass look needs macOS 26)
- Claude Code 2.1 or later, with the desktop app
- Xcode command line tools (`xcode-select --install`)

## Privacy

Mochi reads only the files Claude Code writes on your own Mac, in `~/.claude/mochi/` and the Claude app's own folders. It makes no network calls of its own. Usage checks run the copy of Claude that comes with the app, which reads your usage the same way `/usage` does.

## Licence

MIT. See [LICENSE](LICENSE).
