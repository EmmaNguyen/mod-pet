# Show HN draft

**Before posting:** Read the [Show HN guidelines](https://news.ycombinator.com/showhn.html). The project must be something people can try, and the maker should be ready to answer questions for several hours. Emma posts this herself. Nothing here is posted.

**Title (80 characters or fewer):**

Show HN: Mochi, a pixel companion that shows what Claude Code is doing

**URL:** https://github.com/EmmaNguyen/mod-pet

**First comment (by the maker):**

Hi HN, I'm Emma. Mochi is a small pixel-art companion for Claude Code on macOS. She floats above the message box and shows the state of each chat: working, needs your OK, ready, or blocked. When a chat asks for permission, her card has Allow and Deny buttons, so you can answer without switching windows.

It's a Claude Code plugin plus two small macOS apps (AppKit and SwiftUI). Mochi's own code makes no network requests, and she reads and writes files only in ~/.claude/mochi/ and Claude's own folders. The usage label runs Claude's own /usage check, which contacts Anthropic as /usage does.

Limits, so you know what you're getting: it's a work in progress, macOS 13 or later only, and you build it from source with the Xcode command line tools. It isn't notarised, so macOS will warn you. It's MIT licensed. I built it with Claude Code, and the commit history shows that.

I'd like feedback on the approval flow in particular. The card copies the layout of Claude's own permission dialog, and I'm not sure it's the right trade-off.
