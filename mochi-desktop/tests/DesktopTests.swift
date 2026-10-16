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

// This week: the days, the counts, and the storage
var friday = DateComponents()
friday.year = 2026; friday.month = 10; friday.day = 16; friday.hour = 12
let weekDay = Calendar.current.date(from: friday)!
let weekKeys = weekDates(containing: weekDay).map { dayKey($0) }
check("the week runs Monday to Sunday", weekKeys.count == 7 && weekKeys.first == "2026-10-12" && weekKeys.last == "2026-10-18")
var weekLog: DayLog = [:]
recordTurn(&weekLog, day: "2026-10-12", chatID: "garden", title: "Garden")
recordTurn(&weekLog, day: "2026-10-12", chatID: "garden", title: "Garden")
recordTurn(&weekLog, day: "2026-10-12", chatID: "mochi", title: "Mochi")
check("turns count per day and per chat", weekLog["2026-10-12"]?.turns == 3 && weekLog["2026-10-12"]?.chats["garden"]?.turns == 2)
recordAnswer(&weekLog, day: "2026-10-12", allowed: true)
recordAnswer(&weekLog, day: "2026-10-12", allowed: true)
recordAnswer(&weekLog, day: "2026-10-12", allowed: false)
check("answers count as allowed or declined", weekLog["2026-10-12"]?.allowed == 2 && weekLog["2026-10-12"]?.declined == 1)
check("the peak keeps the highest value", recordPeak(&weekLog, day: "2026-10-12", percent: 61) && !recordPeak(&weekLog, day: "2026-10-12", percent: 40) && weekLog["2026-10-12"]?.peak == 61)
recordTurn(&weekLog, day: "2026-10-13", chatID: "garden", title: "Garden")
let weekSum = weekTotals(weekLog, days: weekKeys)
check("totals add up over the week", weekSum.turns == 4 && weekSum.allowed == 2 && weekSum.declined == 1)
check("the busiest chat comes first", weekSum.chats.first?.id == "garden" && weekSum.chats.first?.turns == 3)
check("a day outside the week is not counted", weekTotals(weekLog, days: ["2026-10-19"]).turns == 0)
let savedLog = try! JSONEncoder().encode(weekLog)
check("a saved log reads back the same", (try? JSONDecoder().decode(DayLog.self, from: savedLog))?["2026-10-12"]?.turns == 3)
let olderRecord = try! JSONDecoder().decode(DayRecord.self, from: #"{"turns":4}"#.data(using: .utf8)!)
check("an older record with missing keys still reads", olderRecord.turns == 4 && olderRecord.allowed == 0 && olderRecord.chats.isEmpty)

// Quiet for an hour: quiet until its end, and never when it is not set
check("an hour of quiet is quiet until the hour is up", quietAt(until: 3_600, now: 3_599) && !quietAt(until: 3_600, now: 3_600))
check("with no quiet set, she is never quiet", !quietAt(until: 0, now: 1_000))

// Answer and session files are tidied: sessions after a week, answers after two weeks, and only .json files
let tidy = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-tidy-test-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tidy, withIntermediateDirectories: true)
let oldAnswer = tidy.appendingPathComponent("old.json"), midAnswer = tidy.appendingPathComponent("mid.json")
let oldText = tidy.appendingPathComponent("old.txt")
for file in [oldAnswer, midAnswer, oldText] { FileManager.default.createFile(atPath: file.path, contents: Data("{}".utf8)) }
let daysAgo: (Int) -> Date = { Date().addingTimeInterval(-Double($0) * 86_400) }
try! FileManager.default.setAttributes([.modificationDate: daysAgo(15)], ofItemAtPath: oldAnswer.path)
try! FileManager.default.setAttributes([.modificationDate: daysAgo(10)], ofItemAtPath: midAnswer.path)
try! FileManager.default.setAttributes([.modificationDate: daysAgo(30)], ofItemAtPath: oldText.path)
let removed = pruneOldFiles(in: tidy, olderThan: 14)
check("a file untouched for 15 days goes at 14 days", removed == 1 && !FileManager.default.fileExists(atPath: oldAnswer.path))
check("a file untouched for 10 days stays at 14 days", FileManager.default.fileExists(atPath: midAnswer.path))
check("a file that is not .json is never deleted", FileManager.default.fileExists(atPath: oldText.path))
try? FileManager.default.removeItem(at: tidy)

// The diary: twelve weeks, the stats, and the streak
var diaryParts = DateComponents()
diaryParts.year = 2026; diaryParts.month = 10; diaryParts.day = 16; diaryParts.hour = 12
let diaryNow = Calendar.current.date(from: diaryParts)!
let diaryGrid = diaryWeeks(now: diaryNow)
check("the diary has twelve weeks, Monday to Sunday", diaryGrid.count == 12 && diaryGrid.allSatisfy { $0.count == 7 })
check("it starts on 27 July and ends on 18 October", dayKey(diaryGrid[0][0]) == "2026-07-27" && dayKey(diaryGrid[11][6]) == "2026-10-18")
var diaryLog: DayLog = [:]
for (day, turns) in [("2026-10-12", 9), ("2026-10-13", 12), ("2026-10-14", 8), ("2026-10-15", 19), ("2026-10-16", 15)] {
    for _ in 0..<turns { recordTurn(&diaryLog, day: day, chatID: "garden", title: "Garden") }
}
let diarySum = diaryStats(diaryLog, now: diaryNow)
check("active days count the days with turns", diarySum.active == 5 && diarySum.total == 82)
check("the busiest day is the one with the most turns", diarySum.busiestKey == "2026-10-15" && diarySum.busiestTurns == 19)
check("the streak runs back from today", diarySum.streak == 5)
var gappedLog = diaryLog
gappedLog["2026-10-14"] = nil
check("a day with no turns breaks the streak", diaryStats(gappedLog, now: diaryNow).streak == 2)
var quietTodayLog = diaryLog
quietTodayLog["2026-10-16"] = nil
check("a quiet today does not break the streak yet", diaryStats(quietTodayLog, now: diaryNow).streak == 4)

print("ALL PASSED")
