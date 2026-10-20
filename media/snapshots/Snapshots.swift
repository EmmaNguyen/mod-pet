// Mochi's screenshot renderer. media/snapshots.sh appends this file to mochi-desktop/main.swift (without its last
// lines, which start the app), the same way test.sh does for the tests, so every image is drawn by the app's real
// views. The chats, usage and diary are made up: nothing is read from ~/.claude/mochi, and nothing is captured
// from the screen. The Liquid Glass behind each box can't be drawn off screen, so a frosted panel stands in for it.

import Foundation

_ = NSApplication.shared
NSApp.appearance = NSAppearance(named: .aqua)

guard CommandLine.arguments.count > 1 else {
    print("usage: snapshots <output folder>")
    exit(2)
}
let outFolder = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)

let now = Date()
let nowMS = now.timeIntervalSince1970 * 1000
let ink = NSColor(hex: 0x3B2A20)

// MARK: - A scene: a soft wallpaper, frosted panels where Liquid Glass would be, and captions

final class Scene: NSView {
    var panels: [(rect: NSRect, radius: CGFloat)] = []
    var captions: [(text: String, rect: NSRect)] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(hex: 0xF9E3D0), NSColor(hex: 0xE6DDF5)])?.draw(in: bounds, angle: -55)
        for panel in panels {
            let shape = NSBezierPath(roundedRect: panel.rect, xRadius: panel.radius, yRadius: panel.radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: 6)
            shadow.set()
            NSColor.white.withAlphaComponent(0.66).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        for caption in captions {
            NSAttributedString(string: caption.text, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style,
            ]).draw(in: caption.rect)
        }
    }
}

func scene(_ width: CGFloat, _ height: CGFloat) -> Scene {
    Scene(frame: NSRect(x: 0, y: 0, width: width, height: height))
}

/// Puts a view in a scene at a point, on a frosted panel when `glass` gives a corner radius
func place(_ view: NSView, in scene: Scene, at origin: NSPoint, glass radius: CGFloat? = nil) {
    view.frame.origin = origin
    scene.addSubview(view)
    if let radius { scene.panels.append((view.frame, radius)) }
}

func caption(_ text: String, in scene: Scene, centerX: CGFloat, y: CGFloat, width: CGFloat = 160) {
    scene.captions.append((text, NSRect(x: centerX - width / 2, y: y, width: width, height: 20)))
}

func save(_ scene: Scene, as name: String) {
    scene.appearance = NSAppearance(named: .aqua)
    let factor: CGFloat = 2
    let size = scene.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * factor), pixelsHigh: Int(size.height * factor),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    scene.cacheDisplay(in: scene.bounds, to: rep)
    let url = outFolder.appendingPathComponent(name)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(name) \(rep.pixelsWide)x\(rep.pixelsHigh)")
}

// MARK: - Made-up data

func usage(five: Int, week: Int, fiveLeft: TimeInterval = 2.2 * 3600) -> Usage {
    Usage(fiveHour: five, week: week, at: nowMS, fiveHourResets: now.addingTimeInterval(fiveLeft),
          weekResets: now.addingTimeInterval(3 * 86400))
}

func event(_ detail: String, seconds: Int, minutesAgo: Double) -> Event {
    Event(kind: "turn", text: "Done", detail: detail, seconds: seconds, at: nowMS - minutesAgo * 60_000)
}

let link = "claude://example"
let chats: [Chat] = [
    Chat(id: "garden-api", title: "garden-api", status: .running,
         log: [event("Added rate limiting to the sessions endpoint", seconds: 41, minutesAgo: 14)],
         updatedAt: nowMS - 20_000, link: link, waiting: ""),
    Chat(id: "billing", title: "billing", status: .needsInput,
         log: [event("Wrote tests for the invoice totals", seconds: 27, minutesAgo: 9)],
         updatedAt: nowMS - 45_000, link: link, waiting: "Run: git push origin main", isRecent: true,
         requestId: "toolu_demo", askedAt: nowMS - 3_000, detail: "git push origin main", mode: "", canSwitchMode: true),
    Chat(id: "docs-site", title: "docs-site", status: .ready,
         log: [event("Fixed the login redirect bug", seconds: 12, minutesAgo: 5), event("Rewrote the install guide", seconds: 33, minutesAgo: 52)],
         updatedAt: nowMS - 5 * 60_000, link: link, waiting: ""),
    Chat(id: "mobile-app", title: "mobile-app", status: .ready,
         log: [event("Moved the settings screen to the new layout", seconds: 58, minutesAgo: 130)],
         updatedAt: nowMS - 130 * 60_000, link: link, waiting: ""),
    Chat(id: "notes", title: "notes", status: .idle, log: [], updatedAt: nowMS - 26 * 3_600_000, link: link, waiting: "", isRecent: false),
]

/// Twelve weeks of made-up diary, the same every run
var seed: UInt64 = 7
func roll() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 33) / Double(1 << 31)
}

/// A Friday at noon, so the week panel shows five busy days whatever day the screenshots are made
let friday: Date = {
    let calendar = Calendar.current
    let monday = weekDates(containing: Date()).first ?? Date()
    let day = calendar.date(byAdding: .day, value: 4, to: monday) ?? monday
    return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
}()

func madeUpDiary(today: Date) -> DayLog {
    var log: DayLog = [:]
    let calendar = Calendar.current
    let names = ["garden-api", "billing", "docs-site", "mobile-app"]
    for back in 0..<84 {
        guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
        let weekend = calendar.isDateInWeekend(date)
        let turns = Int(roll() * roll() * (weekend ? 9 : 24)) + (back < 5 && !weekend ? 5 : 0)
        guard turns > 0 else { continue }
        var record = DayRecord()
        record.turns = turns
        record.allowed = Int(Double(turns) * (0.4 + roll() * 0.3))
        record.declined = roll() < 0.3 ? 1 : 0
        record.peak = 18 + Int(roll() * 66)
        var left = turns
        for name in names.shuffled().prefix(3) where left > 0 {
            let share = max(1, Int(Double(left) * (0.35 + roll() * 0.4)))
            record.chats[name] = ChatDay(title: name, turns: share)
            left -= share
        }
        log[dayKey(date)] = record
    }
    return log
}

// MARK: - Her poses

func mochi(_ status: Status, tick: Int = 8, usage: Usage? = nil) -> MochiView {
    let view = MochiView()
    view.frame = NSRect(x: 0, y: 0, width: 130, height: 162)
    view.status = status
    view.tick = tick
    view.usage = usage
    return view
}

do {
    let s = scene(700, 214)
    let poses: [(Status, String)] = [(.running, "Working"), (.needsInput, "Needs your OK"), (.ready, "Ready"), (.blocked, "Blocked")]
    for (i, pose) in poses.enumerated() {
        let x = 20 + CGFloat(i) * 168
        place(mochi(pose.0, usage: usage(five: 34, week: 51)), in: s, at: NSPoint(x: x, y: 24))
        caption(pose.1, in: s, centerX: x + 65, y: 170)
    }
    save(s, as: "01-status.png")
}

do {
    let s = scene(560, 214)
    place(mochi(.running, usage: usage(five: 44, week: 20)), in: s, at: NSPoint(x: 20, y: 24))
    caption("Under 70%", in: s, centerX: 85, y: 170)
    place(mochi(.running, usage: usage(five: 82, week: 45)), in: s, at: NSPoint(x: 195, y: 24))
    caption("Past 70%: eyes get a lid", in: s, centerX: 260, y: 170, width: 190)
    place(mochi(.running, usage: usage(five: 74, week: 45, fiveLeft: 25 * 60)), in: s, at: NSPoint(x: 370, y: 24))
    caption("Under an hour left", in: s, centerX: 435, y: 170, width: 190)
    save(s, as: "02-mood-and-countdown.png")
}

do {
    let s = scene(470, 250)
    let buttons = mochi(.idle, usage: usage(five: 34, week: 51))
    buttons.forceShow = true
    place(buttons, in: s, at: NSPoint(x: 20, y: 24))
    caption("Note, talk, diary", in: s, centerX: 85, y: 196)
    let listening = mochi(.idle, usage: usage(five: 34, week: 51))
    listening.forceShow = true
    listening.recording = true
    place(listening, in: s, at: NSPoint(x: 195, y: 24))
    caption("Listening", in: s, centerX: 260, y: 196)
    let auto = mochi(.running, usage: usage(five: 34, week: 51))
    auto.autoMode = true
    place(auto, in: s, at: NSPoint(x: 340, y: 24))
    caption("Auto mode", in: s, centerX: 405, y: 196)
    save(s, as: "03-buttons-and-auto.png")
}

// MARK: - Cards beside her

do {
    let s = scene(480, 262)
    let card = ApprovalView(title: approvalQuestion(chat: "billing", waiting: "Run: git push origin main"),
                            subtitle: "Answer in 7 seconds, or Claude asks you itself.",
                            body: "git push origin main", accent: Status.needsInput.color, offersModes: true)
    card.dot = chatColor("billing")
    place(card, in: s, at: NSPoint(x: 30, y: 24), glass: 18)
    save(s, as: "04-approval-card.png")
}

do {
    let s = scene(360, 170)
    let finished = CardView(title: "✓ docs-site · 12s", body: "Fixed the login redirect bug", accent: Status.ready.color)
    finished.dot = chatColor("docs-site")
    place(finished, in: s, at: NSPoint(x: 30, y: 24), glass: 18)
    let warning = CardView(title: "⚠️ 5-hour usage at 90%", body: "Week: 41% used", accent: NSColor(hex: 0xE03131))
    place(warning, in: s, at: NSPoint(x: 30, y: 92), glass: 18)
    save(s, as: "05-finished-and-usage-cards.png")
}

// MARK: - Her list and the usage box

do {
    let list = ChatListView()
    list.chats = chats
    list.usage = usage(five: 62, week: 38)
    list.title = boardTitle(needing: 1)
    list.titleColor = Status.needsInput.color
    list.subtitle = boardSubtitle(approving: 0, open: chats.filter(\.isOpen).count)
    list.footer = "Click a chat to open it in Claude"
    list.activityLines = [
        (runningText(titles: ["garden-api"]), ChatListView.runningInk),
        (finishedText(title: "docs-site", updated: nowMS - 5 * 60_000), Status.ready.color),
    ]
    list.frame = NSRect(x: 0, y: 0, width: ChatListView.width, height: list.fittingHeight())
    let s = scene(ChatListView.width + 60, list.frame.height + 48)
    place(list, in: s, at: NSPoint(x: 30, y: 24), glass: 22)
    save(s, as: "06-chat-list.png")
}

do {
    let panel = UsagePanelView()
    panel.usage = usage(five: 62, week: 38)
    panel.footnote = "Checked just now"
    panel.frame = NSRect(x: 0, y: 0, width: UsagePanelView.width, height: panel.fittingHeight())
    let s = scene(UsagePanelView.width + 60, panel.frame.height + 48)
    place(panel, in: s, at: NSPoint(x: 30, y: 24), glass: 22)
    save(s, as: "07-usage-panel.png")
}

// MARK: - This week, the diary, and her thoughts

let diary = madeUpDiary(today: friday)
let weekUsage = Usage(fiveHour: 62, week: 38, at: nowMS, fiveHourResets: nil,
                      weekResets: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: friday.addingTimeInterval(3 * 86400)))
for (tab, name) in [(0, "08-this-week.png"), (1, "09-diary.png")] {
    let week = WeekView(log: diary, usage: weekUsage, now: friday, colorFor: { chatColor($0) })
    week.tab = tab
    let s = scene(WeekView.size.width + 60, WeekView.size.height + 48)
    place(week, in: s, at: NSPoint(x: 30, y: 24), glass: 24)
    save(s, as: name)
}

do {
    let thoughts = [
        Thought(kind: .timeLeft, big: "2 h 12 min left", small: "in your 5-hour window. Plenty, go on!"),
        Thought(kind: .ready, big: "2 chats ready for you", small: "I'll keep the rest warm. No rush."),
        Thought(kind: .fact, big: "Did you know?", small: funFacts.first ?? "Cats sleep for most of the day."),
    ]
    let s = scene(ThoughtView.size.width + 60, CGFloat(thoughts.count) * (ThoughtView.size.height - 8) + 40)
    for (i, thought) in thoughts.enumerated() {
        place(ThoughtView(thought: thought), in: s, at: NSPoint(x: 30, y: 16 + CGFloat(i) * (ThoughtView.size.height - 8)))
    }
    save(s, as: "10-thoughts.png")
}

// MARK: - Her trot for the demo video: one PNG per frame, on a transparent background, from the app's own view

let walkFolder = outFolder.deletingLastPathComponent().appendingPathComponent("video/walk")
try? FileManager.default.createDirectory(at: walkFolder, withIntermediateDirectories: true)
for frame in 0..<24 {
    let view = mochi(.running, tick: frame)
    let factor: CGFloat = 4
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * factor),
                                     pixelsHigh: Int(view.bounds.height * factor), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                     bitsPerPixel: 0) else { continue }
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    let url = walkFolder.appendingPathComponent(String(format: "walk-%02d.png", frame))
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}
print("wrote 24 walk frames to \(walkFolder.path)")
