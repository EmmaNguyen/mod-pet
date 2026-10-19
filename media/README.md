# Mochi media package

Press and launch assets for Mochi, the pixel-art companion for Claude Code on macOS. Use [copy/facts.md](copy/facts.md) to check any claim before it goes out.

## What's here

| Path | What it is |
| --- | --- |
| `logo/mochi-logo-1024.png` | Mochi, classic orange, 1024×1024, transparent background |
| `logo/skins/` | Each of the six skins, 512×512, transparent background |
| `images/skins-lineup.png` | All six skins in one image, with names |
| `gif/mochi-working-4x.gif` | The working animation, scaled 4× from `docs/mochi-working.gif` |
| `social/github-social-1280x640.png` | GitHub social preview (repo settings) |
| `social/card-1200x630.png` | Link card for X, Bluesky, and Reddit |
| `copy/facts.md` | Verified facts, with sources, and things not to say yet |
| `copy/taglines.md` | One-line, 50-word, and 150-word descriptions |
| `posts/show-hn.md` | Show HN title and first comment |
| `posts/reddit-claudeai.md` | r/ClaudeAI title and body |
| `posts/x-bluesky.md` | Three-post X and Bluesky draft |
| `screenshots/README.md` | Shot list for the real screenshots, not yet captured |

## Rebuilding the images

The images are generated from the app's own sprite grid and skin palettes, so they stay accurate after UI changes:

```bash
python3 media/build.py
```

It needs Pillow (`pip3 install pillow`). It writes only into `media/`.

## Still to do

- Real screenshots of the running app (see [screenshots/README.md](screenshots/README.md)).
- Decide the licence for these assets. Code stays MIT. A proposal is CC BY 4.0 for images and copy.
- Check the "mods announced 1 October 2026" date against Anthropic's documentation before using it anywhere.
- Post the drafts yourself, after checking each channel's rules.
