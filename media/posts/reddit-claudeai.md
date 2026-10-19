# r/ClaudeAI draft

**Before posting:** Read the subreddit's rules and any self-promotion or flair rules, and check whether a pinned "share your project" thread is the right place. Emma posts this herself. Nothing here is posted.

**Flair:** pick the one that fits, such as "Project" or "Built with Claude", if the subreddit has them.

**Title:**

I made Mochi, a pixel-art companion that shows what your Claude Code chats are doing (macOS, open source)

**Body:**

Mochi sits above your message box and shows the state of every Claude Code chat: working, needs your OK, ready, or blocked. When a chat asks for permission, her card has Allow and Deny buttons, so you don't have to switch windows.

- Six skins, chosen from her right-click menu
- Mochi Studio, a separate app, to change her colour, eyes, accessory, and name
- A usage label that shows your 5-hour and weekly limits
- A small "this week" view and a diary of your busiest days

It's a Claude Code plugin with two small macOS apps, MIT licensed. Mochi's own code makes no network requests. The usage check runs Claude's own /usage copy, which contacts Anthropic the same way /usage does.

Limits: work in progress, macOS 13 or later, built from source with the Xcode command line tools, and not notarised, so macOS will warn you on first launch.

Repo: https://github.com/EmmaNguyen/mod-pet

Happy to answer questions, and feedback on what breaks is very welcome.

[attach: media/gif/mochi-working-4x.gif]
