// Mochi Desktop's logic tests. test.sh appends this file to main.swift (without its last lines, which start
// the app), so these run against the real code.

func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { exit(1) }
}

func chat(_ id: String, _ req: String, _ asked: Double, mode: String = "", canSwitch: Bool = true) -> Chat {
    Chat(id: id, title: id, status: .needsInput, log: [], updatedAt: 0, link: nil, waiting: "", isRecent: true,
         requestId: req, askedAt: asked, detail: "", mode: mode, canSwitchMode: canSwitch)
}

// Which chat a key answers
let real = chat("higgsfield", "toolu_real", 1_000), test = chat("mochi-test", "test-1", 14_000)
check("during a test, a key answers the test card, not a real chat",
      keyTarget([real, test], showing: ["toolu_real", "test-1"], testID: "test-1").chat?.id == "mochi-test")
check("one card showing: a key answers it", keyTarget([real], showing: ["toolu_real"], testID: nil).chat?.id == "higgsfield")
let two = keyTarget([real, chat("garden", "toolu_other", 2_000)], showing: ["toolu_real", "toolu_other"], testID: nil)
check("two cards showing: a key answers neither", two.chat == nil && two.waiting == 2)
check("no card showing: nothing", keyTarget([real], showing: [], testID: nil).chat == nil)
check("an ended test does not hold the keys", keyTarget([real], showing: ["toolu_real"], testID: "test-gone").chat?.id == "higgsfield")
check("a chat with no request is never picked", keyTarget([chat("x", "", 0)], showing: [""], testID: nil).chat == nil)

// Reading what a chat reports
let decoder = JSONDecoder()
let newer = try! decoder.decode(Report.self, from: #"{"status":"running","mode":"auto","detail":"$ ls"}"#.data(using: .utf8)!)
let older = try! decoder.decode(Report.self, from: #"{"status":"running"}"#.data(using: .utf8)!)
check("a report from the new plugin carries its mode", newer.mode == "auto" && newer.detail == "$ ls")
check("a report from an older plugin has no mode, so it cannot switch modes", older.mode == nil)

// Usage colours, which her tired eyes follow
check("usage under 70% is green", Usage.color(69) == NSColor(hex: 0x2F9E44))
check("70% is orange", Usage.color(70) == NSColor(hex: 0xF08C00))
check("90% is red", Usage.color(90) == NSColor(hex: 0xE03131))

// The approval card's question, worded like Claude's own dialog
check("a command asks to run a command", approvalQuestion(chat: "garden", waiting: "Run: npm publish") == "Allow garden to run a command?")
check("an edit names the file", approvalQuestion(chat: "garden", waiting: "Edit login.ts") == "Allow garden to edit login.ts?")
check("a web page names the address", approvalQuestion(chat: "garden", waiting: "Open example.com/page") == "Allow garden to open example.com/page?")
check("a tool names the tool", approvalQuestion(chat: "garden", waiting: "Use create_issue") == "Allow garden to use create_issue?")
check("no description still asks", approvalQuestion(chat: "garden", waiting: "") == "Allow garden to go ahead?")

// The approval keys listed in the menu
check("no card: no approval keys listed", approvalShortcutLines(nil).isEmpty)
check("a card from an older chat: only allow and deny",
      approvalShortcutLines(chat("old", "r", 0, canSwitch: false)) == ["Allow    ⌃⌥1", "Deny    ⌃⌥2"])
check("a card from a newer chat: the mode keys too",
      approvalShortcutLines(chat("new", "r", 0, canSwitch: true)).count == 4)

// The countdown on an approval card
check("a card just asked has the whole window left", answerSecondsLeft(askedAt: 0, now: 0, window: 7_000) == 7)
check("2.5 seconds on, 5 seconds are left", answerSecondsLeft(askedAt: 0, now: 2_500, window: 7_000) == 5)
check("at the end of the window, none are left", answerSecondsLeft(askedAt: 0, now: 7_000, window: 7_000) == 0)
check("past the window, still none", answerSecondsLeft(askedAt: 0, now: 9_000, window: 7_000) == 0)

print("ALL PASSED")
