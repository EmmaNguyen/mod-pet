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
check("quiet until turned back on stays quiet for years", quietAt(until: quietForever, now: 1_800_000_000))
check("quiet until turned back on shows no end time", quietEndsText(until: quietForever).isEmpty)
check("a timed quiet shows its end time", !quietEndsText(until: 3_600).isEmpty)

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

// Mochi's thoughts: what she says, and when
check("a time shows as hours and minutes, or minutes", timeLeftText(17_520) == "4 h 52 min" && timeLeftText(360) == "6 min")
let thinkNow = Date(timeIntervalSince1970: 1_800_000_000)
let calmUsage = Usage(fiveHour: 20, week: 40, at: 0, fiveHourResets: thinkNow.addingTimeInterval(17_520))
let timeThought = pickThought(usage: calmUsage, readyChats: 0, now: thinkNow, roll: 0, factIndex: 0)
check("with time left, she says how long is left in the window",
      timeThought?.kind == .timeLeft && timeThought?.big == "4 h 52 min left")
let tiredUsage = Usage(fiveHour: 97, week: 40, at: 0, fiveHourResets: thinkNow.addingTimeInterval(360))
let lowThought = pickThought(usage: tiredUsage, readyChats: 0, now: thinkNow, roll: 0, factIndex: 0)
check("near the limit, she says so and suggests a stretch",
      lowThought?.kind == .lowTime && lowThought?.big == "6 min left" && lowThought?.small.contains("97%") == true)
let pastReset = Usage(fiveHour: 20, week: 40, at: 0, fiveHourResets: thinkNow.addingTimeInterval(-60))
check("a window that has already reset gives no time thought",
      pickThought(usage: pastReset, readyChats: 0, now: thinkNow, roll: 0, factIndex: 0)?.kind == .fact)
check("with no usage and no ready chats, she shares a fact",
      pickThought(usage: nil, readyChats: 0, now: thinkNow, roll: 0.5, factIndex: 1)?.small == funFacts[1])
let readyThought = pickThought(usage: nil, readyChats: 3, now: thinkNow, roll: 0, factIndex: 0)
check("ready chats are counted in the words", readyThought?.kind == .ready && readyThought?.big == "3 chats ready for you")
check("one ready chat is singular", pickThought(usage: nil, readyChats: 1, now: thinkNow, roll: 0, factIndex: 0)?.big == "1 chat ready for you")
check("the roll picks among the thoughts that could be said", pickThought(usage: calmUsage, readyChats: 0, now: thinkNow, roll: 0.99, factIndex: 0)?.kind == .fact)
check("a fact index past the end is clamped", pickThought(usage: nil, readyChats: 0, now: thinkNow, roll: 0, factIndex: 99)?.small == funFacts.last)

// What may pop up: with "only tell me when something needs my approval" on, only approvals
check("approvals always pop up", noticeAllowed(.approval, onlyApprovals: true) && noticeAllowed(.approval, onlyApprovals: false))
check("finished work, usage and thoughts stay quiet when only approvals are wanted",
      !noticeAllowed(.finished, onlyApprovals: true) && !noticeAllowed(.usage, onlyApprovals: true))
check("her thoughts still pop up when only approvals is on", noticeAllowed(.thought, onlyApprovals: true))
check("everything pops up when only approvals is off", noticeAllowed(.finished, onlyApprovals: false) && noticeAllowed(.usage, onlyApprovals: false) && noticeAllowed(.thought, onlyApprovals: false))

// Which requests need you: changes do, looking does not
check("a command that changes something needs you", needsYou(waiting: "Run: npm publish"))
check("a command that only looks does not", !needsYou(waiting: "Run: ls -la") && !needsYou(waiting: "Run: cat notes.md"))
check("read-only git does not, but a push does", !needsYou(waiting: "Run: git status") && needsYou(waiting: "Run: git push"))
check("reading and searching files do not", !needsYou(waiting: "Use Read") && !needsYou(waiting: "Use Grep"))
check("writing a tool or an edit does, and so do questions", needsYou(waiting: "Use create_issue") && needsYou(waiting: "Edit login.ts") && needsYou(waiting: "Asks: Which database?"))

// Her list groups chats by what needs you
check("running chats come first", listGroup(.running) == 0)
check("chats that need you, or are stopped, come second", listGroup(.needsInput) == 1 && listGroup(.blocked) == 1)
check("finished chats come third, and resting ones last", listGroup(.ready) == 2 && listGroup(.idle) == 3 && listGroup(.ended) == 3)

// Her list shows only the latest news of each chat until it is expanded
check("only the latest news shows when collapsed", listShownEvents(total: 5, expanded: false) == 1)
check("all the news shows when expanded", listShownEvents(total: 5, expanded: true) == 5)
check("a chat with no news shows none", listShownEvents(total: 0, expanded: false) == 0)

// Her usage box names the state from the fuller limit
check("usage under 70% is on track", usageState(worst: 0) == "On track" && usageState(worst: 69) == "On track")
check("usage from 70% is getting high, from 90% almost out, and 100% out", usageState(worst: 70) == "Getting high" && usageState(worst: 90) == "Almost out" && usageState(worst: 100) == "Out of usage")

// Finished chats: only the latest ten are listed, newest first
let manyDone = (0..<12).map { Double($0) }
let kept = recentFirst(manyDone, updated: { $0 }, limit: finishedLimit)
check("only the latest ten finished chats are kept", kept.count == 10 && kept.first == 11 && kept.last == 2)
check("fewer than ten finished chats are all kept", recentFirst([1.0, 2.0], updated: { $0 }, limit: finishedLimit).count == 2)

// The chat list is wider than the approval cards
check("the chat list is wider than the approval cards", ChatListView.width > ApprovalView.size.width)

// A chat in the Claude app is running while it had activity in the last two minutes
check("a chat active a minute ago is running", isActiveNow(updated: 60_000, now: 120_000))
check("a chat quiet for three minutes is not", !isActiveNow(updated: 0, now: 180_000))

// The board's heading names what needs you, and the line under it names the chats approving on their own
check("the heading is plain Mochi with nothing waiting", boardTitle(needing: 0) == "Mochi")
check("the heading counts chats waiting for you", boardTitle(needing: 1) == "Mochi · 1 waiting" && boardTitle(needing: 3) == "Mochi · 3 waiting")
check("a waiting chat's box says Waiting, not Needs you", listStateLabel(.needsInput) == "Waiting" && listStateLabel(.running) == "Working")
check("the subtitle names the chats approving on their own", boardSubtitle(approving: 2, open: 5) == "2 chats approving on their own")
check("with none approving on their own, the subtitle counts open chats", boardSubtitle(approving: 0, open: 1) == "1 open chat" && boardSubtitle(approving: 0, open: 4) == "4 open chats")

// Running now is always listed at the top, even when empty; the others are left out when empty
check("the running group is always shown", groupAlwaysShown(0))
check("the other groups are left out when empty", !groupAlwaysShown(1) && !groupAlwaysShown(2) && !groupAlwaysShown(3))

// The chat box names the session running now, and the one that finished last
check("no running session is named as none", runningText(titles: []) == "Nothing running right now")
check("the running sessions are named", runningText(titles: ["A", "B"]) == "Running: A, B")
check("with nothing finished, the line says so", finishedText(title: nil, updated: nil) == "Nothing finished lately")
check("the finished session is named with its time", finishedText(title: "Mod pet", updated: 0).hasPrefix("Finished: Mod pet · "))

// The running text is the deep blue, not the light one, so it reads on the glass
check("the running heading uses the deep blue", ChatListView.groups[0].color == ChatListView.runningInk && ChatListView.runningInk != Status.running.color)

// A chat's mode is the Claude app's own record when it has one, so an Auto chat shows as Auto
check("the app's mode wins over the plugin's report", effectiveMode(app: "auto", report: "default") == "auto")
check("the plugin's mode is used when the app has none", effectiveMode(app: nil, report: "acceptEdits") == "acceptEdits" && effectiveMode(app: "", report: "acceptEdits") == "acceptEdits")
check("a chat with no mode anywhere has an empty one", effectiveMode(app: nil, report: nil) == "")

// Only running chats in Auto count as approving on their own
let autoRunning = Chat(id: "x", title: "X", status: .running, log: [], updatedAt: 0, link: nil, waiting: "", mode: "auto")
let autoDone = Chat(id: "y", title: "Y", status: .ready, log: [], updatedAt: 0, link: nil, waiting: "", mode: "auto")
check("a running Auto chat is approving on its own", approvingOnItsOwn(autoRunning))
check("a finished Auto chat is not", !approvingOnItsOwn(autoDone))

// The chat list leaves room on the right for the scrollbar
check("the chat list keeps a gutter for the scrollbar", ChatListView.gutter >= 20)

// The last hour of the 5-hour window counts down from 60 to 0
let lowNow = Date(timeIntervalSince1970: 1_000_000)
check("25 minutes left shows 25", lowTimeMinutes(resets: lowNow.addingTimeInterval(25 * 60 + 30), now: lowNow) == 25)
check("45 minutes left shows 45", lowTimeMinutes(resets: lowNow.addingTimeInterval(45 * 60 + 30), now: lowNow) == 45)
check("60 minutes exactly shows 60", lowTimeMinutes(resets: lowNow.addingTimeInterval(60 * 60), now: lowNow) == 60)
check("over 60 minutes left shows nothing", lowTimeMinutes(resets: lowNow.addingTimeInterval(61 * 60), now: lowNow) == nil)
check("a window that has reset shows nothing", lowTimeMinutes(resets: lowNow.addingTimeInterval(-60), now: lowNow) == nil)
check("no reset time shows nothing", lowTimeMinutes(resets: nil, now: lowNow) == nil)

// A reset offer: read as "yyyy-mm-dd, count", usable to the end of that day, and counted in days left
let offerGood = parseResetOffer("2026-10-22, 1")
check("a reset offer reads its count", offerGood?.count == 1)
check("a reset offer is usable until the end of its day", offerGood.map { Calendar.current.component(.day, from: $0.useBy) } == 22 && offerGood.map { Calendar.current.component(.hour, from: $0.useBy) } == 23)
check("a reset offer without a count does not read", parseResetOffer("2026-10-22") == nil)
check("a reset offer with no resets does not read", parseResetOffer("2026-10-22, 0") == nil)
check("a reset offer with a bad date does not read", parseResetOffer("soon, 1") == nil)
let offerNow = Date(timeIntervalSince1970: 1_000_000)
check("2.5 days left shows 3 days", resetOfferDaysLeft(useBy: offerNow.addingTimeInterval(2.5 * 86400), now: offerNow) == 3)
check("an offer that has passed shows no days", resetOfferDaysLeft(useBy: offerNow.addingTimeInterval(-1), now: offerNow) == nil)

// A task timer: the estimate is the last finished turn, and the line and circle say how long is left
let timerLog = [Event(kind: "turn", text: "Done", detail: nil, seconds: 900, at: 1000), Event(kind: "turn", text: "Done", detail: nil, seconds: 300, at: 500)]
check("the estimate is the longest of the recent finished turns", taskEstimate(timerLog) == 900)
let sixTurns = (0..<6).map { Event(kind: "turn", text: "Done", detail: nil, seconds: $0 == 0 ? 2000 : 60, at: Double($0) * 1000) }
check("the estimate looks only at the last five turns", taskEstimate(sixTurns) == 60)
check("a chat with no finished turn has no estimate", taskEstimate([]) == nil)
check("the timer says minutes left on the estimate", taskTimerText(elapsed: 360, estimate: 900) == "Running for 6 min · about 9 min left")
check("past the estimate the timer shows elapsed time only", taskTimerText(elapsed: 1000, estimate: 900) == "Running for 16 min")
check("the timer with no estimate shows elapsed only", taskTimerText(elapsed: 180, estimate: nil) == "Running for 3 min · no estimate yet")
check("the bar fills to the estimate and stops there", taskProgress(elapsed: 450, estimate: 900) == 0.5 && taskProgress(elapsed: 1800, estimate: 900) == 1)
check("Mochi's circle counts the minutes left", taskCircleMinutes(elapsed: 360, estimate: 900) == 9)
check("Mochi's circle is gone once the estimate has passed", taskCircleMinutes(elapsed: 1000, estimate: 900) == nil && taskCircleMinutes(elapsed: 0, estimate: nil) == nil)

// A mochi:// link starts or stops a countdown on a chat
check("a countdown link names the chat and the minutes", parseMochiLink(URL(string: "mochi://countdown?chat=Redo%20the%20search&minutes=47")!) == .countdown(chat: "Redo the search", minutes: 47))
check("a stop link with a chat names it", parseMochiLink(URL(string: "mochi://stop?chat=Redo")!) == .stop(chat: "Redo"))
check("a stop link with no chat stops any countdown", parseMochiLink(URL(string: "mochi://stop")!) == .stop(chat: nil))
check("a countdown link without minutes is not read", parseMochiLink(URL(string: "mochi://countdown?chat=Redo")!) == nil)
check("a countdown link with zero minutes is not read", parseMochiLink(URL(string: "mochi://countdown?chat=Redo&minutes=0")!) == nil)
check("another scheme or host is not read", parseMochiLink(URL(string: "https://countdown?chat=Redo&minutes=5")!) == nil && parseMochiLink(URL(string: "mochi://other")!) == nil)
let linkChats = [
    Chat(id: "a", title: "Redo the search", status: .ready, log: [], updatedAt: 100, link: nil, waiting: "", isRecent: true, requestId: "", askedAt: 0, detail: "", mode: "auto", canSwitchMode: true),
    Chat(id: "b", title: "Build the report", status: .running, log: [], updatedAt: 200, link: nil, waiting: "", isRecent: true, requestId: "", askedAt: 0, detail: "", mode: "", canSwitchMode: true),
]
check("a countdown names the chat it finds by part of its title", chatNamed("redo", in: linkChats)?.id == "a")
check("a name that matches no open chat finds none", chatNamed("nothing", in: linkChats) == nil)

// A stopped chat goes back to normal after ten minutes
check("a chat that stopped a minute ago is still stopped", settledStatus(.blocked, updated: 0, now: 60_000) == .blocked)
check("a chat that stopped ten minutes ago is back to normal", settledStatus(.blocked, updated: 0, now: 600_000) == .ready)
check("other statuses are not changed by the timeout", settledStatus(.running, updated: 0, now: 9_000_000) == .running)

// Time per chat per day: each second counts as working or waiting for you, and reads as words
check("no time reads as 0m, and under a minute reads in words", clockText(0) == "0m" && clockText(30) == "under a minute")
check("minutes and hours read as words", clockText(22 * 60) == "22m" && clockText(3 * 3600 + 40 * 60) == "3h 40m")
var timeLog: DayLog = [:]
recordSecond(&timeLog, day: "2026-10-21", chatID: "a", title: "Redo the search", waiting: false)
recordSecond(&timeLog, day: "2026-10-21", chatID: "a", title: "Redo the search", waiting: false)
recordSecond(&timeLog, day: "2026-10-21", chatID: "a", title: "Redo the search", waiting: true)
check("a working second and a waiting second are counted apart", timeLog["2026-10-21"]?.chats["a"]?.working == 2 && timeLog["2026-10-21"]?.chats["a"]?.waiting == 1)

// Her three buttons show only when the pointer is near her
let mochiFrame = NSRect(x: 100, y: 100, width: 130, height: 162)
check("the buttons show when the pointer is over her", buttonsShowFor(pointer: NSPoint(x: 150, y: 150), frame: mochiFrame))
check("the buttons show when the pointer is just beside her", buttonsShowFor(pointer: NSPoint(x: 240, y: 150), frame: mochiFrame))
check("the buttons stay hidden when the pointer is far away", !buttonsShowFor(pointer: NSPoint(x: 600, y: 600), frame: mochiFrame))

// /usage after a reset has no reset time, so Mochi still reads the percentage
let usageAfterReset = "Current session: 0% used\nCurrent week (all models): 0% used · resets Oct 25 at 2am (Asia/Saigon)"
check("a session line with no reset time still reads", usageReading(in: usageAfterReset, line: "Current session")?.percent == 0 && usageReading(in: usageAfterReset, line: "Current session")?.resets == nil)
check("a week line with a reset time reads both", usageReading(in: usageAfterReset, line: "Current week[^:]*")?.percent == 0 && usageReading(in: usageAfterReset, line: "Current week[^:]*")?.resets == "Oct 25 at 2am (Asia/Saigon)")
check("a session line with a reset time reads both", usageReading(in: "Current session: 58% used · resets Oct 19 at 6:40pm (Asia/Saigon)", line: "Current session")?.percent == 58)
check("text with no usage line reads nothing", usageReading(in: "nothing here", line: "Current session") == nil)

// The ring round her badge fills with progress, and goes green for a minute after a chat finishes
check("the ring fills to 60 percent at 216 degrees", ringSweepDegrees(0.6) == 216)
check("the ring never goes past a full circle or below nothing", ringSweepDegrees(1.5) == 360 && ringSweepDegrees(-0.2) == 0)
check("the ring is green for a minute after a chat finishes", ringShowsFinished(finishedAt: Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 1030)))
check("the ring stops being green after a minute", !ringShowsFinished(finishedAt: Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 1061)))
check("the ring is not green when nothing has finished", !ringShowsFinished(finishedAt: nil, now: Date()))

// A chat with the plugin loaded counts as running while an agent keeps it busy, unless it waits for you
check("a busy chat that the plugin reports as ready is running", liveStatus(.ready, activeNow: true) == .running)
check("a chat waiting for you stays waiting", liveStatus(.needsInput, activeNow: true) == .needsInput)
check("a quiet chat keeps its reported status", liveStatus(.ready, activeNow: false) == .ready)

// The brief shows at 8:00 AM and 8:00 PM, once each, and says what needs you
var briefCal = Calendar(identifier: .gregorian)
briefCal.timeZone = TimeZone.current
func briefAt(_ hour: Int, _ minute: Int) -> Date { briefCal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: hour, minute: minute))! }
check("the morning brief is due at 8:00 AM", briefSlot(now: briefAt(8, 0), lastShown: nil, calendar: briefCal)?.hasSuffix("AM") == true)
check("the wrap-up is due at 6:00 PM", briefSlot(now: briefAt(18, 0), lastShown: nil, calendar: briefCal)?.hasSuffix("PM") == true)
check("the wrap-up is not due at 5:59 PM", briefSlot(now: briefAt(17, 59), lastShown: nil, calendar: briefCal)?.hasSuffix("PM") != true)
check("a brief is not due before 8:00 AM", briefSlot(now: briefAt(7, 30), lastShown: nil, calendar: briefCal) == nil)
check("a missed 8:00 AM brief is due later that morning", briefSlot(now: briefAt(9, 18), lastShown: nil, calendar: briefCal)?.hasSuffix("AM") == true)
check("a brief shows once per slot", briefSlot(now: briefAt(8, 0), lastShown: briefSlot(now: briefAt(8, 0), lastShown: nil, calendar: briefCal), calendar: briefCal) == nil)
let briefChats = [
    Chat(id: "a", title: "Mod pet", status: .needsInput, log: [], updatedAt: 100, link: nil, waiting: "Run: ls", isRecent: true, requestId: "r", askedAt: 0, detail: "", mode: "auto", canSwitchMode: true),
    Chat(id: "b", title: "Redo the search", status: .running, log: [], updatedAt: 200, link: nil, waiting: "", isRecent: true, requestId: "", askedAt: 0, detail: "", mode: "auto", canSwitchMode: true),
]
let briefLog: DayLog = [:]
let morning = briefContent(kind: "morning", chats: briefChats, log: briefLog, now: briefAt(8, 0), offer: nil, usagePercent: nil)
check("the morning brief counts the chats waiting and running", morning.stats.map { $0.value }.prefix(2) == ["1", "1"])
check("the morning brief lists the chat that needs you first", morning.rows.first?.left == "Mod pet")
let quietMorning = briefContent(kind: "morning", chats: [], log: briefLog, now: briefAt(8, 0), offer: nil, usagePercent: nil)
check("with nothing waiting, the brief says so", quietMorning.lines.first?.0 == "Nothing needs you" && quietMorning.rows.isEmpty)
var dayWork: DayLog = [:]
dayWork[dayKey(briefAt(20, 0))] = {
    var record = DayRecord()
    record.turns = 5
    record.allowed = 12
    record.chats["a"] = ChatDay(title: "Redo the search", turns: 3, working: 7800, waiting: 600)
    record.chats["b"] = ChatDay(title: "Build the report", turns: 2, working: 3900, waiting: 480)
    return record
}()
let evening = briefContent(kind: "evening", chats: [], log: dayWork, now: briefAt(20, 0), offer: nil, usagePercent: 38)
check("the wrap-up headline is today's working time", evening.headline?.big == "3h 15m")
check("the wrap-up counts finished chats, approvals and usage", evening.stats.map { $0.value } == ["5", "12", "38%"])
check("the wrap-up lists the top chat first", evening.top.first?.name == "Redo the search" && evening.top.count == 2)
check("the wrap-up chart has a bar for each day with today marked", evening.week.count == 7 && evening.week.filter { $0.isToday }.count == 1)
let offerContent = briefContent(kind: "evening", chats: [], log: briefLog, now: briefAt(20, 0), offer: ResetOffer(count: 1, useBy: briefAt(23, 23)), usagePercent: nil)
check("the brief shows an open reset offer", offerContent.footer?.hasPrefix("Reset offer: 1 left") == true)

// Agents are read from their own transcripts: the task is the first user message, and an agent is running if it was active in the last two minutes
let agentLine = #"{"isSidechain":true,"agentId":"ac7c","type":"user","message":{"role":"user","content":"Run the find-roles task with the saved filters\nand report back"},"timestamp":"2026-10-23T03:08:49.401Z"}"#
let readAgent = agentTask(fromLine: agentLine)
check("an agent's task is its first line of the first user message", readAgent?.task == "Run the find-roles task with the saved filters")
let agentFormat = ISO8601DateFormatter()
agentFormat.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
check("an agent's task has its exact start time", readAgent?.at == agentFormat.date(from: "2026-10-23T03:08:49.401Z"))
check("a line that is not a user message gives no task", agentTask(fromLine: #"{"type":"api-request"}"#) == nil)
check("an agent active a minute ago is running", agentActive(lastActivity: Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 1060)))
check("an agent quiet for three minutes is not running", !agentActive(lastActivity: Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 1180)))

// The brief card follows Mochi: centred under her, above her when there is no room below, and kept on screen
let briefScreen = NSRect(x: 0, y: 0, width: 1000, height: 800)
let underHer = briefOrigin(under: NSRect(x: 400, y: 500, width: 130, height: 162), width: 380, height: 200, screen: briefScreen)
check("the brief sits centred under her", underHer.x == 400 + 65 - 190 && underHer.y == 500 - 200 - 6)
let nearBottom = briefOrigin(under: NSRect(x: 400, y: 10, width: 130, height: 162), width: 380, height: 200, screen: briefScreen)
check("with no room below her, the brief goes above her", nearBottom.y == 10 + 162 + 6)
let nearEdge = briefOrigin(under: NSRect(x: 0, y: 500, width: 130, height: 162), width: 380, height: 200, screen: briefScreen)
check("the brief stays on screen at the left edge", nearEdge.x == 4)

// The morning brief and the wrap-up use the Duet look; the agent list keeps the plain card
check("the morning brief is drawn in the Duet look with a greeting", morning.duet && morning.title == "Good morning.")
check("the wrap-up is drawn in the Duet look", evening.duet && evening.title == "Today's wrap-up.")
check("the agent list keeps the plain card", !BriefContent().duet)

// A mochi://brief link shows the morning brief, or the wrap-up when asked
check("a brief link shows the morning brief by default", parseMochiLink(URL(string: "mochi://brief")!) == .brief(kind: "morning"))
check("a brief link can ask for the wrap-up", parseMochiLink(URL(string: "mochi://brief?kind=evening")!) == .brief(kind: "evening"))

// The brief lists the seven most recently active sessions, newest first
let manySessions = (0..<10).map { Chat(id: "s\($0)", title: "Session \($0)", status: .ready, log: [], updatedAt: Double($0), link: nil, waiting: "", isRecent: true, requestId: "", askedAt: 0, detail: "", mode: "", canSwitchMode: false) }
let newestSeven = latestSessions(manySessions)
check("the latest sessions are the seven most recently active", newestSeven.count == 7 && newestSeven.first?.id == "s9" && newestSeven.last?.id == "s3")
check("with fewer than seven sessions, all of them are listed", latestSessions(Array(manySessions.prefix(3))).count == 3)
check("the brief carries the latest sessions", briefContent(kind: "evening", chats: manySessions, log: [:], now: Date(), offer: nil, usagePercent: nil).latest.count == 7)

// Each latest session carries its real chat link, so a click opens that chat
let linked = [Chat(id: "L", title: "Linked session", status: .ready, log: [], updatedAt: 5, link: "claude://code/continue?session=abc", waiting: "", isRecent: true, requestId: "", askedAt: 0, detail: "", mode: "", canSwitchMode: false)]
check("a session row carries its chat link", briefContent(kind: "evening", chats: linked, log: [:], now: Date(), offer: nil, usagePercent: nil).latest.first?.link == "claude://code/continue?session=abc")

// The week panel takes a new day record while it is open, so its chart moves live
let liveWeek = WeekView(log: [:], usage: nil, now: Date(), colorFor: { _ in .gray })
var newerLog: DayLog = [:]
recordTurn(&newerLog, day: "2026-10-25", chatID: "W", title: "Week chat")
liveWeek.update(log: newerLog, usage: nil, now: Date())
check("the week chart takes a newer day record", liveWeek.log["2026-10-25"]?.turns == 1)

// A waiting chat in the morning brief carries its real chat link, so a click opens it
let waitingChat = [Chat(id: "W1", title: "Waiting session", status: .needsInput, log: [], updatedAt: 5, link: "claude://code/continue?session=wait", waiting: "Approve: ls", isRecent: true, requestId: "r", askedAt: 0, detail: "", mode: "", canSwitchMode: false)]
check("a waiting row carries its chat link", briefContent(kind: "morning", chats: waitingChat, log: [:], now: Date(), offer: nil, usagePercent: nil).rows.first?.link == "claude://code/continue?session=wait")

// A skin picked from the right-click menu shows, even when Mochi Studio paints a body colour
var studioLook = MochiLook()
studioLook.body = "F5F7FA"
check("a picked skin beats the Studio body colour", bodyColour(look: studioLook, skin: skins[1], picked: true) == skins[1].face)
check("Studio's body shows until a skin is picked", bodyColour(look: studioLook, skin: skins[1], picked: false) == studioLook.bodyColor)

print("ALL PASSED")
