# Screenshots

These are drawn by Mochi's own views, with made-up chats, by `sh media/snapshots.sh`. They are not captured from a screen, so no real chat names can appear. Liquid Glass can't be drawn off screen, so a frosted panel stands in for it.

| File | Shows |
| --- | --- |
| `01-status.png` | The four poses: working, needs your OK, ready, blocked |
| `02-mood-and-countdown.png` | Tired eyes past 70%, and the countdown under an hour |
| `03-buttons-and-auto.png` | The note, talk and diary buttons, listening, and Auto mode |
| `04-approval-card.png` | The approval card with Allow and Deny |
| `05-finished-and-usage-cards.png` | A finished-work card and a usage warning card |
| `06-chat-list.png` | Her list of chats, grouped by what they are doing |
| `07-usage-panel.png` | The usage box |
| `08-this-week.png`, `09-diary.png` | The two tabs of her week panel |
| `10-thoughts.png` | Three kinds of thought bubble |
| `11-studio.png` | Mochi Studio, with a sample look |

## Regenerating

```sh
sh media/snapshots.sh
```

It needs only the Xcode command line tools. The renderers are `media/snapshots/Snapshots.swift` (Mochi Desktop) and `media/snapshots/StudioSnapshot.swift` (Mochi Studio). `snapshots.sh` appends each one to the app's `main.swift`, cut just before the app starts, so the images always come from the current code. Change the made-up data in those two files.

## Not covered yet

Real screen captures are still wanted for the Liquid Glass look, the quick note box, and the right-click menu (skins, quiet, test the approval keys). They need Screen Recording permission for the terminal, and any capture must have chat names, usage numbers and personal paths redacted.
