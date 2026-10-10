// Mochi Desktop: a floating pixel cat that sits anywhere on your screen and
// tells you what every Claude Code chat is doing.
//
// Each chat (through the pet-mod plugin) writes a small file to
// ~/.claude/mochi/sessions/<chat>.json with its status and recent events.
// Mochi reads them all every second, shows the most urgent status, and pops a
// bubble and a Mac notification when something new happens, from every chat
// (projects and chats with no folder alike). Drag her anywhere; click her for
// the notifications; right-click for the menu.

import AppKit
import ServiceManagement
import UserNotifications

// MARK: - What the chats report

enum Status: String {
    case idle, running, ready, blocked, ended
    case needsInput = "needs-input"

    /// The most urgent status wins when several chats are open
    var urgency: Int {
        switch self {
        case .needsInput: return 5
        case .blocked: return 4
        case .running: return 3
        case .ready: return 2
        case .idle: return 1
        case .ended: return 0
        }
    }

    var color: NSColor {
        switch self {
        case .idle, .ended: return NSColor(hex: 0xAE3EC9)
        case .running: return NSColor(hex: 0x1C7ED6)
        case .needsInput: return NSColor(hex: 0xE03131)
        case .ready: return NSColor(hex: 0x2F9E44)
        case .blocked: return NSColor(hex: 0x495057)
        }
    }

    var label: String {
        switch self {
        case .idle, .ended: return "Resting"
        case .running: return "Working"
        case .needsInput: return "Needs you"
        case .ready: return "Ready"
        case .blocked: return "Blocked"
        }
    }
}

struct Event: Decodable {
    let kind: String
    let text: String
    /// One short line on what it was: a summary of Claude's answer, or why it stopped
    let detail: String?
    let seconds: Int?
    let at: Double?

    /// The words to show: the summary when there is one, else the plain text
    var summary: String { detail.flatMap { $0.isEmpty ? nil : $0 } ?? text }

    /// "✓ garden · 12s", "✗ garden stopped · 4s", "⚙ garden"
    func headline(_ chat: String) -> String {
        let took = seconds.map { " · \($0)s" } ?? ""
        switch (kind, text) {
        case ("turn", "Stopped"): return "✗ \(chat) stopped\(took)"
        case ("helper", _): return "• \(chat) helper\(took)"
        default: return "\(icons[kind] ?? "•") \(chat)\(took)"
        }
    }
}

struct Report: Decodable {
    let title: String?
    let link: String?
    let waiting: String?
    let status: String
    let log: [Event]?
    let updatedAt: Double?
}

struct Chat {
    let id: String
    let title: String
    let status: Status
    let log: [Event]
    let updatedAt: Double
    /// Opens this chat in the Claude app; terminal chats have none
    let link: String?
    /// What Claude wants your OK for, in a few words
    let waiting: String
    /// Active in the last few hours: only these set Mochi's mood
    var isRecent = true
    var isOpen: Bool { status != .ended }
}

/// Brings Claude to the front on that chat
func openChat(_ link: String?) {
    guard let link, let url = URL(string: link), url.scheme == "claude" else { return }
    NSWorkspace.shared.open(url)
}

/// "now", "5m", "2h"
func ago(_ ms: Double?) -> String {
    let seconds = max(0, Date().timeIntervalSince1970 - (ms ?? 0) / 1000)
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    return "\(Int(seconds / 3600))h"
}

/// Cuts text to a length, ending with "…"
func clip(_ text: String, _ max: Int) -> String {
    text.count > max ? String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
}

let icons = ["turn": "✓", "helper": "•", "task": "⚙", "routine": "⏰", "message": "✉"]
let sessionsFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/mochi/sessions")

/// The Claude app's own record of one chat: its title, and its summary of the last turn
struct AppSession: Decodable {
    struct Summary: Decodable {
        let status_category: String?
        let status_detail: String?
        let needs_action: String?
        let summarizes_uuid: String?
    }
    let sessionId: String
    let cliSessionId: String?
    let title: String?
    let lastActivityAt: Double?
    let isArchived: Bool?
    let postTurnSummary: Summary?
}

/// Where the Claude app keeps its chats: one folder per account and organisation
let appSessionsFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

/// The app's records, re-read only when a file changes
var appCache: [URL: (Date, AppSession)] = [:]

/// Every chat in the Claude app, from its own records, whether or not it loaded the mod
func readAppSessions() -> [AppSession] {
    let fm = FileManager.default
    var found: [AppSession] = []
    var seenFiles = Set<URL>()
    let accounts = (try? fm.contentsOfDirectory(at: appSessionsFolder, includingPropertiesForKeys: nil)) ?? []
    for account in accounts {
        let orgs = (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? []
        for org in orgs {
            let files = (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
                seenFiles.insert(url)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if let cached = appCache[url], cached.0 == modified { found.append(cached.1); continue }
                guard let data = try? Data(contentsOf: url),
                      let session = try? JSONDecoder().decode(AppSession.self, from: data) else { continue }
                appCache[url] = (modified, session)
                found.append(session)
            }
        }
    }
    appCache = appCache.filter { seenFiles.contains($0.key) }
    return found
}

/// Every chat, project or not: the mod's live reports, and every chat the Claude app knows of
func readChats() -> [Chat] {
    let now = Date().timeIntervalSince1970 * 1000
    let recent = 6 * 3600 * 1000.0 // only chats active this recently set Mochi's mood

    // The mod's live reports, from the last 12 hours
    var live: [String: Chat] = [:]
    let files = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil)) ?? []
    for url in files where url.pathExtension == "json" {
        guard let data = try? Data(contentsOf: url),
              let report = try? JSONDecoder().decode(Report.self, from: data),
              let status = Status(rawValue: report.status),
              now - (report.updatedAt ?? 0) < 12 * 3600 * 1000
        else { continue }
        let id = url.deletingPathExtension().lastPathComponent
        live[id] = Chat(id: id, title: report.title ?? "Claude", status: status, log: report.log ?? [],
                        updatedAt: report.updatedAt ?? 0, link: report.link, waiting: report.waiting ?? "",
                        isRecent: now - (report.updatedAt ?? 0) < recent)
    }

    var chats: [Chat] = []
    for session in readAppSessions() where session.isArchived != true {
        let updated = session.lastActivityAt ?? 0
        guard now - updated < 3 * 24 * 3600 * 1000 else { continue } // the last three days
        let link = "claude://code/continue?session=\(session.sessionId)&source=mochi"
        let title = session.title ?? "Claude chat"

        // A chat with the mod loaded: its live status, under the app's title
        if let cli = session.cliSessionId, let mine = live.removeValue(forKey: cli) {
            chats.append(Chat(id: mine.id, title: title, status: mine.status, log: mine.log,
                              updatedAt: max(mine.updatedAt, updated), link: mine.link ?? link,
                              waiting: mine.waiting, isRecent: mine.isRecent))
            continue
        }

        // Any other chat: the app's own summary of its last turn
        let summary = session.postTurnSummary
        let needs = summary?.needs_action ?? ""
        let category = summary?.status_category ?? ""
        let status: Status = !needs.isEmpty ? .needsInput
            : category == "blocked" ? .blocked
            : category == "completed" ? .ready
            : .idle
        var log: [Event] = []
        if let summary, let detail = summary.status_detail, !detail.isEmpty {
            let text = !needs.isEmpty ? "Needs you" : category == "blocked" ? "Stopped" : "Done"
            log.append(Event(kind: "turn", text: text, detail: needs.isEmpty ? detail : needs, seconds: nil, at: updated))
        }
        chats.append(Chat(id: session.sessionId, title: title, status: status, log: log, updatedAt: updated,
                          link: link, waiting: needs, isRecent: now - updated < recent))
    }

    // Terminal chats the app does not know of
    chats.append(contentsOf: live.values)
    return chats
}

// MARK: - Mochi's pixels (the same 16x16 cat as in the Claude window)

let grid = [
    "................",
    "..K..........K..",
    ".KBK........KBK.",
    ".KPBK......KBPK.",
    ".KBBBKKKKKKBBBK.",
    ".KBBBBBBBBBBBBK.",
    "KBBLBBBBBBBBLBBK",
    "KBBEWBBBBBBEWBBK",
    "KBBeeBBBBBBeeBBK",
    "KBPBBBBKKBBBBPBK",
    "KBBBBBBBBBBBBBBK",
    ".KBBDBBBBBBDBBK.",
    "..KKBBLLLLBBKK..",
    "..KBBKBLLBKBBK..",
    "..KBBK.KK.KBBK..",
    "...KK......KK...",
]
/// A look for Mochi: the colours of her body and her eyes. The shape never changes.
struct Skin {
    let name: String
    let palette: [Character: NSColor]
    let face: NSColor
    let eye: NSColor
}

let skins: [Skin] = [
    Skin(name: "Classic orange", palette: [
        "K": NSColor(hex: 0x3B2A20), "B": NSColor(hex: 0xF4A259), "L": NSColor(hex: 0xFFE0B5),
        "P": NSColor(hex: 0xFF8FAB), "D": NSColor(hex: 0xD9822B)], face: NSColor(hex: 0xF4A259), eye: NSColor(hex: 0x2B2118)),
    Skin(name: "Midnight black", palette: [
        "K": NSColor(hex: 0x101014), "B": NSColor(hex: 0x3A3A48), "L": NSColor(hex: 0x5B5B6E),
        "P": NSColor(hex: 0x8A5A7A), "D": NSColor(hex: 0x2A2A36)], face: NSColor(hex: 0x3A3A48), eye: NSColor(hex: 0xF5D547)),
    Skin(name: "Snow white", palette: [
        "K": NSColor(hex: 0x6B6B78), "B": NSColor(hex: 0xF5F7FA), "L": NSColor(hex: 0xFFFFFF),
        "P": NSColor(hex: 0xFFB3C6), "D": NSColor(hex: 0xDFE4EA)], face: NSColor(hex: 0xF5F7FA), eye: NSColor(hex: 0x3B82F6)),
    Skin(name: "Tuxedo", palette: [
        "K": NSColor(hex: 0x1A1A1A), "B": NSColor(hex: 0xF8F8F8), "L": NSColor(hex: 0xFFFFFF),
        "P": NSColor(hex: 0xFFB3C6), "D": NSColor(hex: 0x2B2B2B)], face: NSColor(hex: 0xF8F8F8), eye: NSColor(hex: 0x2B2B2B)),
    Skin(name: "Mint", palette: [
        "K": NSColor(hex: 0x2B4A44), "B": NSColor(hex: 0x8FD9B6), "L": NSColor(hex: 0xD4F5E4),
        "P": NSColor(hex: 0xFFA8C5), "D": NSColor(hex: 0x5FBF96)], face: NSColor(hex: 0x8FD9B6), eye: NSColor(hex: 0x1F3D37)),
    Skin(name: "Lavender galaxy", palette: [
        "K": NSColor(hex: 0x2A1B4A), "B": NSColor(hex: 0xB197FC), "L": NSColor(hex: 0xE5DBFF),
        "P": NSColor(hex: 0xFF8FD8), "D": NSColor(hex: 0x7950F2)], face: NSColor(hex: 0xB197FC), eye: NSColor(hex: 0x2A1B4A)),
]

/// The skin Mochi wears; remembered between launches
var skinIndex: Int {
    get { min(max(UserDefaults.standard.integer(forKey: "skinIndex"), 0), skins.count - 1) }
    set { UserDefaults.standard.set(newValue, forKey: "skinIndex") }
}
var palette: [Character: NSColor] {
    var colours = skins[skinIndex].palette
    if let body = currentLook.bodyColor { colours["B"] = body }
    return colours
}
var face: NSColor { currentLook.bodyColor ?? skins[skinIndex].face }
var eye: NSColor { skins[skinIndex].eye }

/// How Mochi Studio has dressed her. Missing or unreadable means the defaults.
struct MochiLook: Decodable {
    var body: String?
    var eyes: String?
    var accessory: String?
    var name: String?
    var speed: Double?

    var bodyColor: NSColor? {
        guard let body, let v = UInt32(body, radix: 16) else { return nil }
        return NSColor(hex: Int(v))
    }
    static func read() -> MochiLook {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/mochi/look.json")
        guard let data = try? Data(contentsOf: url), let look = try? JSONDecoder().decode(MochiLook.self, from: data) else {
            return MochiLook()
        }
        return look
    }
}

/// Mochi's look as last read from Mochi Studio, refreshed every second
var currentLook = MochiLook()

func pixelColor(_ cell: Character, _ status: Status, blinking: Bool) -> NSColor? {
    switch cell {
    case "E": return status == .blocked || blinking || currentLook.eyes == "sleepy" ? face : eye
    case "W": return status == .blocked || blinking || currentLook.eyes == "sleepy" ? face : status == .ready ? eye : .white
    case "e": return status == .ready ? face : eye
    case ".": return nil
    default: return palette[cell]
    }
}

// MARK: - Mochi's window

let scale: CGFloat = 5
let petSize = CGFloat(16) * scale

final class MochiView: NSView {
    var status: Status = .idle
    var unread = 0
    /// Plan usage, shown as a small label under her
    var usage: Usage?
    /// Where the usage label is drawn, so a click on it can be told from a click on her
    var usagePill: NSRect = .zero
    var onUsageClick: (() -> Void)?
    var tick = 0
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var grab: NSPoint?
    private var dragged = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = Double(tick) / 12 * (currentLook.speed ?? 1)
        let blinking = status != .ready && status != .blocked && tick % 48 >= 46

        // How she moves: trots while working, hops when ready, wiggles when she needs you
        var lift: CGFloat = 0
        var tilt: CGFloat = 0
        switch status {
        case .running: lift = CGFloat(abs(sin(t * 7)) * 4)
        case .ready: lift = CGFloat(max(0, sin(t * 4)) * 10)
        case .needsInput: tilt = CGFloat(sin(t * 8) * 0.09)
        case .idle, .ended: lift = CGFloat(sin(t * 2) * 1.2)
        case .blocked: break
        }

        let originX = (bounds.width - petSize) / 2
        let originY = bounds.height - petSize - 24 - lift // room for the usage label below
        ctx.saveGState()
        ctx.translateBy(x: originX + petSize / 2, y: originY + petSize / 2)
        ctx.rotate(by: tilt)
        ctx.translateBy(x: -petSize / 2, y: -petSize / 2)
        for (y, row) in grid.enumerated() {
            for (x, cell) in row.enumerated() {
                guard var color = pixelColor(cell, status, blinking: blinking) else { continue }
                if status == .blocked { color = color.blended(withFraction: 0.75, of: .gray) ?? color }
                color.setFill()
                NSRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale).fill()
            }
        }
        drawAccessory(currentLook.accessory ?? "none")
        ctx.restoreGState()

        drawBadge(at: NSPoint(x: originX + petSize - 4, y: originY + 6))
        if unread > 0 { drawUnread(at: NSPoint(x: originX + 4, y: originY + 6)) }
        if let usage { drawUsage(usage) }
    }

    /// The little status dot by her ear: dots, a clock, a check, a cross or a "z"
    /// An accessory from Mochi Studio, drawn in her own grid squares (5 points each)
    private func drawAccessory(_ name: String) {
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
        }
        switch name {
        case "bow":
            NSColor(hex: 0x1C7ED6).setFill()
            NSBezierPath(ovalIn: box(5, 1.5, 3, 2.5)).fill()
            NSBezierPath(ovalIn: box(8, 1.5, 3, 2.5)).fill()
        case "hat":
            NSColor(hex: 0x3A3A48).setFill()
            NSBezierPath(rect: box(4, -1, 8, 1.2)).fill()
            NSBezierPath(rect: box(5.5, -4, 5, 3.2)).fill()
        case "scarf":
            NSColor(hex: 0xE03131).setFill()
            NSBezierPath(rect: box(3, 11, 10, 1.6)).fill()
            NSBezierPath(rect: box(10, 12.2, 2, 2.2)).fill()
        default: break
        }
    }

    private func drawBadge(at center: NSPoint) {
        let r: CGFloat = 9
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        status.color.setFill()
        ring.fill()
        NSColor.white.setStroke()
        ring.lineWidth = 2
        ring.stroke()

        let glyph: String
        switch status {
        case .running: glyph = ["·  ", "·· ", "···"][(tick / 4) % 3]
        case .needsInput: glyph = "!"
        case .ready: glyph = "✓"
        case .blocked: glyph = "✕"
        case .idle, .ended: glyph = "z"
        }
        let text = NSAttributedString(string: glyph, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    /// A small pill under her: "5h 34% · wk 12%", coloured by the fuller of the two
    private func drawUsage(_ usage: Usage) {
        var words = "5h \(usage.fiveHour)% · wk \(usage.week)%"
        if let blocked = usage.blocked {
            words = blocked.until.map { "Back \(Usage.clock($0))" } ?? "Limit reached"
        }
        let text = NSAttributedString(string: words, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let pill = NSRect(x: (bounds.width - size.width) / 2 - 7, y: bounds.height - 19, width: size.width + 14, height: 16)
        usagePill = pill
        Usage.color(max(usage.fiveHour, usage.week)).withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + (pill.height - size.height) / 2))
    }

    /// How many things finished that you have not looked at yet
    private func drawUnread(at center: NSPoint) {
        let r: CGFloat = 8
        NSColor(hex: 0xE03131).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
        let text = NSAttributedString(string: unread > 9 ? "9+" : "\(unread)", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    // Drag her anywhere; a click without a drag opens the notifications
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        grab = NSPoint(x: mouse.x - window.frame.origin.x, y: mouse.y - window.frame.origin.y)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let grab else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
        dragged = true
        NotificationCenter.default.post(name: .mochiMoved, object: nil)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged {
            let point = convert(event.locationInWindow, from: nil)
            if usagePill.insetBy(dx: -4, dy: -4).contains(point) { onUsageClick?() } else { onClick?() }
        }
        if dragged, let origin = window?.frame.origin {
            UserDefaults.standard.set([origin.x, origin.y], forKey: "origin")
        }
        grab = nil
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

extension Notification.Name {
    static let mochiMoved = Notification.Name("mochiMoved")
}

// MARK: - The speech bubble and the notification list

/// One line of the bubble: bold lines are headings, coloured by their chat's status
struct Line {
    let text: String
    var bold = false
    var color: NSColor? = nil
    var indent: CGFloat = 0
    var dim = false
    /// Clicking this line opens that chat in Claude
    var link: String? = nil
}

final class BubbleView: NSView {
    var lines: [Line] = []
    var accent: NSColor = .systemBlue
    override var isFlipped: Bool { true }

    static let font = NSFont.systemFont(ofSize: 12)
    static let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let widest = lines.map { line in
            NSAttributedString(string: line.text, attributes: [.font: line.bold ? Self.bold : Self.font]).size().width + line.indent
        }.max() ?? 0
        return NSSize(width: min(maxWidth, widest + 24), height: CGFloat(lines.count) * 18 + 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, line) in lines.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let color = line.color ?? (line.dim ? NSColor.secondaryLabelColor : NSColor.labelColor)
            NSAttributedString(string: line.text, attributes: [
                .font: line.bold ? Self.bold : Self.font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]).draw(in: NSRect(x: 12 + line.indent, y: 8 + CGFloat(i) * 18,
                               width: bounds.width - 24 - line.indent, height: 18))
        }
    }

    /// Clicking a chat's line opens it in Claude; anywhere else closes the bubble
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - 8) / 18)
        if lines.indices.contains(row), let link = lines[row].link { openChat(link) }
        window?.orderOut(nil)
    }

    override func resetCursorRects() {
        for (i, line) in lines.enumerated() where line.link != nil {
            addCursorRect(NSRect(x: 0, y: 8 + CGFloat(i) * 18, width: bounds.width, height: 18), cursor: .pointingHand)
        }
    }
}

/// The rounded box behind the bubble; the lines scroll inside it
final class BubbleFrame: NSView {
    var accent: NSColor = .systemBlue
    let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds.insetBy(dx: 4, dy: 4)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Nothing to draw: the Liquid Glass behind is the box
}

func floatingPanel(size: NSSize) -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.hidesOnDeactivate = false
    return panel
}

// MARK: - Notification cards beside Mochi

/// One notification beside Mochi: a coloured edge, a bold title, one line of
/// detail, and a small ✕. Clicking the card opens the chat; the ✕ just closes it.
final class CardView: NSView {
    let title: String
    let body: String
    let accent: NSColor
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }

    static let size = NSSize(width: 300, height: 56)
    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 11.5)

    init(title: String, body: String, accent: NSColor) {
        self.title = title
        self.body = body
        self.accent = accent
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var closeBox: NSRect { NSRect(x: bounds.width - 28, y: 8, width: 18, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        // The Liquid Glass behind draws the card itself; only the coloured edge is drawn here
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 10, y: 13, width: 4, height: bounds.height - 26), xRadius: 2, yRadius: 2).fill()

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: title, attributes: [
            .font: Self.titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]).draw(in: NSRect(x: 22, y: 10, width: bounds.width - 52, height: 18))
        NSAttributedString(string: body, attributes: [
            .font: Self.bodyFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]).draw(in: NSRect(x: 22, y: 29, width: bounds.width - 34, height: 17))
        NSAttributedString(string: "✕", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
        ]).draw(at: NSPoint(x: closeBox.minX + 4, y: closeBox.minY + 2))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeBox.contains(point) { onClose?() } else { onOpen?() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Plan usage, as the Claude app last saw it

struct UsageFile: Decodable {
    struct Sample: Decodable {
        struct Used: Decodable { let fh: Double?; let sd: Double? }
        let t: Double
        let u: Used
    }
    let samples: [Sample]
}

/// The live reading the mod writes each time Claude reports usage
struct LiveUsageFile: Decodable {
    let fiveHour: Double?
    let fiveHourResetsAt: String?
    let week: Double?
    let weekResetsAt: String?
    let at: Double
}

/// How much of your plan is used: the 5-hour window and the week, in percent, when each resets, and when it was read
struct Usage {
    let fiveHour: Int
    let week: Int
    let at: Double
    var fiveHourResets: Date? = nil
    var weekResets: Date? = nil

    /// The newest reading: the mod's live one, or else what the Claude app last saved
    static func read() -> Usage? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var best: Usage?
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude/mochi/usage.json")),
           let live = try? JSONDecoder().decode(LiveUsageFile.self, from: data) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            func date(_ text: String?) -> Date? { text.flatMap { iso.date(from: $0) ?? plain.date(from: $0) } }
            best = Usage(fiveHour: Int((live.fiveHour ?? 0).rounded()), week: Int((live.week ?? 0).rounded()), at: live.at,
                         fiveHourResets: date(live.fiveHourResetsAt), weekResets: date(live.weekResetsAt))
        }
        if let data = try? Data(contentsOf: home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")),
           let file = try? JSONDecoder().decode(UsageFile.self, from: data),
           let last = file.samples.max(by: { $0.t < $1.t }), last.t > (best?.at ?? 0) {
            best = Usage(fiveHour: Int(last.u.fh ?? 0), week: Int(last.u.sd ?? 0), at: last.t)
        }
        // A window that has reset since the reading is empty again
        if var usage = best {
            let now = Date()
            if let reset = usage.fiveHourResets, reset < now { usage = Usage(fiveHour: 0, week: usage.week, at: usage.at, fiveHourResets: nil, weekResets: usage.weekResets) }
            if let reset = usage.weekResets, reset < now { usage = Usage(fiveHour: usage.fiveHour, week: 0, at: usage.at, fiveHourResets: usage.fiveHourResets, weekResets: nil) }
            return usage
        }
        return nil
    }

    /// The limit you have hit, if any: when you can use Claude again (nil date: reached, reset time unknown)
    var blocked: (what: String, until: Date?)? {
        let five: (String, Date?)? = fiveHour >= 100 ? ("5-hour limit", fiveHourResets) : nil
        let wk: (String, Date?)? = week >= 100 ? ("Weekly limit", weekResets) : nil
        switch (five, wk) {
        case let (a?, b?): return a.1 == nil || b.1 == nil ? (b.0, nil) : (a.1! > b.1! ? a : b) // both: the later one
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// "3:40 PM", "tomorrow 8:00 AM", "Mon 8:00 AM"
    static func clock(_ date: Date) -> String {
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInTomorrow(date) { return "tomorrow " + time.string(from: date) }
        let day = DateFormatter()
        day.dateFormat = "EEE"
        return day.string(from: date) + " " + time.string(from: date)
    }

    /// "Back at 3:40 PM · in 2h 10m", or just "Limit reached" when no reset time is known
    var backText: String? {
        guard let blocked else { return nil }
        guard let until = blocked.until else { return "\(blocked.what) reached" }
        return "Back at \(Usage.clock(until)) · in \(Usage.until(until) ?? "0m")"
    }

    /// "2h 10m", "35m"
    static func until(_ date: Date?) -> String? {
        guard let date else { return nil }
        let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
        if minutes >= 24 * 60 { return "\(minutes / (24 * 60))d \((minutes / 60) % 24)h" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// "▰▰▰▱▱" for a percentage
    static func bar(_ percent: Int) -> String {
        let filled = min(5, max(0, Int((Double(percent) / 20).rounded(.up))))
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: 5 - filled)
    }

    static func color(_ percent: Int) -> NSColor {
        percent >= 90 ? NSColor(hex: 0xE03131) : percent >= 70 ? NSColor(hex: 0xF08C00) : NSColor(hex: 0x2F9E44)
    }

    /// "5h ▰▰▱▱▱ 34% (resets 2h 10m) · Week ▰▱▱▱▱ 12% · now"
    var line: String {
        let five = Usage.until(fiveHourResets).map { " (resets \($0))" } ?? ""
        let wk = Usage.until(weekResets).map { " (resets \($0))" } ?? ""
        return "5h \(Usage.bar(fiveHour)) \(fiveHour)%\(five)  ·  Week \(Usage.bar(week)) \(week)%\(wk)  ·  \(ago(at))"
    }
}

// MARK: - Asking Claude for fresh usage: `claude -p "/usage"`

/// Finds the Claude command-line tool the app ships with (the newest version), or the one on the PATH
func claudeToolPath() -> String? {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code")
    let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    for version in versions.sorted(by: >) {
        let dir = root.appendingPathComponent(version)
        if let found = FileManager.default.enumerator(atPath: dir.path)?.compactMap({ $0 as? String })
            .first(where: { $0.hasSuffix("claude.app/Contents/MacOS/claude") }) {
            return dir.appendingPathComponent(found).path
        }
    }
    return ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Reads "Oct 9 at 1:39pm (Asia/Saigon)" into a date
func parseResetDate(_ text: String) -> Date? {
    guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")") else { return nil }
    let zone = TimeZone(identifier: String(text[text.index(after: open)..<close])) ?? .current
    // "1:59am" must read as AM: the formatter only matches the upper-case markers
    let stamp = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "am", with: "AM").replacingOccurrences(of: "pm", with: "PM")
    let year = Calendar.current.component(.year, from: Date())
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = zone
    f.amSymbol = "AM"; f.pmSymbol = "PM"
    // "1:39PM" and the on-the-hour "2AM" both occur
    for format in ["yyyy MMM d 'at' h:mma", "yyyy MMM d 'at' ha"] {
        f.dateFormat = format
        if let date = f.date(from: "\(year) \(stamp)") { return date }
    }
    return nil
}

/// Asks Claude for the exact usage, the same way you would by typing /usage, and saves it for Mochi
func refreshUsageFromClaude(_ done: @escaping (Bool) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        guard let tool = claudeToolPath() else { done(false); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-p", "/usage"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice // never wait for keyboard input
        do { try process.run() } catch { done(false); return }
        // Never wait more than 30 seconds
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        killer.cancel()

        let five = try? NSRegularExpression(pattern: "Current session: (\\d+)% used · resets ([^\\n]+)")
        let week = try? NSRegularExpression(pattern: "Current week[^:]*: (\\d+)% used · resets ([^\\n]+)")
        func match(_ regex: NSRegularExpression?) -> (Int, Date?)? {
            guard let regex, let m = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                  let pct = Range(m.range(at: 1), in: output), let when = Range(m.range(at: 2), in: output)
            else { return nil }
            return (Int(output[pct]) ?? 0, parseResetDate(String(output[when])))
        }
        guard let fiveNow = match(five), let weekNow = match(week) else { done(false); return }

        let iso = ISO8601DateFormatter()
        let report: [String: Any] = [
            "fiveHour": fiveNow.0,
            "fiveHourResetsAt": fiveNow.1.map { iso.string(from: $0) } ?? NSNull(),
            "week": weekNow.0,
            "weekResetsAt": weekNow.1.map { iso.string(from: $0) } ?? NSNull(),
            "at": Date().timeIntervalSince1970 * 1000,
        ]
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/mochi")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: folder.appendingPathComponent("usage.json"))
        }
        done(true)
    }
}

// MARK: - The app

final class Mochi: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let window = floatingPanel(size: NSSize(width: 130, height: 124))
    let view = MochiView()
    let bubble = floatingPanel(size: NSSize(width: 260, height: 40))
    let bubbleView = BubbleView()
    let bubbleFrame = BubbleFrame(frame: NSRect(x: 0, y: 0, width: 260, height: 40))
    /// The Liquid Glass the list and speech bubble sit on
    lazy var bubbleGlass: NSView = makeGlass(size: bubbleFrame.frame.size, content: bubbleFrame, radius: 18)
    /// The tallest the bubble gets before it scrolls
    let bubbleMaxHeight: CGFloat = 440
    var seen = Set<String>()
    var firstLook = true
    var needed = Set<String>()
    var hideBubble: Timer?
    var chats: [Chat] = []
    /// The last usage warning given, so each level is said once: 80 then 100, for each window
    /// True while a usage check is running; when the last one finished
    var usageBusy = false
    var usageCheckedAt: Date?
    /// Whether you were out of usage at the last look, to tell when it comes back
    var wasBlocked = false
    var warnedFiveHour = 0
    var warnedWeek = 0
    var usage: Usage?

    /// The notification cards beside Mochi, newest first
    var cards: [NSPanel] = []
    static let maxCards = 5

    /// Mac notifications are on unless you switch them off in her menu
    var macNotifications: Bool {
        get { UserDefaults.standard.object(forKey: "macNotifications") as? Bool ?? false } // cards beside Mochi instead
        set { UserDefaults.standard.set(newValue, forKey: "macNotifications") }
    }
    /// macOS could not register Mochi for notifications; fall back to a plain one
    var notificationsUnavailable = false

    /// The sound she makes when a chat needs you: one of the Mac's own, or "None"
    static let sounds = ["Purr", "Glass", "Ping", "Submarine", "Hero", "Tink"]
    var needsSound: String {
        get { UserDefaults.standard.string(forKey: "needsSound") ?? "Purr" }
        set { UserDefaults.standard.set(newValue, forKey: "needsSound") }
    }

    /// Plays the "a chat needs you" sound, whatever the notification settings
    func playNeedsSound() {
        guard needsSound != "None" else { return }
        NSSound(named: NSSound.Name(needsSound))?.play()
    }

    /// Whether macOS opens Mochi when you log in (System Settings → General → Login Items)
    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Mochi: could not change Open at login: \(error)")
        }
        UserDefaults.standard.set(on, forKey: "openAtLoginChosen")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Only one Mochi at a time: if she is already running, this copy bows out
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }

        // Open at login unless you switched it off in her menu
        if UserDefaults.standard.object(forKey: "openAtLoginChosen") == nil || UserDefaults.standard.bool(forKey: "openAtLoginChosen") {
            if !opensAtLogin { setOpensAtLogin(true) }
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if error != nil { self?.notificationsUnavailable = true }
        }

        window.contentView = view
        bubbleFrame.scroll.documentView = bubbleView
        bubbleFrame.autoresizingMask = [.width, .height]
        bubble.contentView = bubbleGlass
        bubble.hasShadow = false // the glass draws its own soft edge

        // Where you left her last time, or the bottom-right corner
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        if let saved = UserDefaults.standard.array(forKey: "origin") as? [CGFloat], saved.count == 2 {
            window.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
        } else {
            window.setFrameOrigin(NSPoint(x: screen.maxX - 150, y: screen.minY + 40))
        }
        window.orderFrontRegardless()

        view.onClick = { [weak self] in self?.toggleNotifications() }
        view.onUsageClick = { [weak self] in self?.showUsageDetails() }
        view.onMenu = { [weak self] event in self?.showMenu(event) }
        NotificationCenter.default.addObserver(forName: .mochiMoved, object: nil, queue: .main) { [weak self] _ in
            self?.placeBubble()
            self?.placeCards()
        }

        Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.view.tick += 1
            self.view.needsDisplay = true
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.look() }
        // Keep the usage numbers fresh in the background, so a click shows them at once
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refreshUsageQuietly() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshUsageQuietly() }
        look()
    }

    /// Reads every chat, picks the most urgent status, and announces anything new
    func look() {
        currentLook = MochiLook.read()
        chats = readChats()
        checkUsage()
        view.status = chats.filter { $0.isOpen && $0.isRecent }.max(by: { $0.status.urgency < $1.status.urgency })?.status ?? .idle

        var fresh: [(Event, Chat)] = []
        for chat in chats {
            for event in chat.log {
                let key = "\(chat.id)|\(event.at ?? 0)|\(event.text)"
                if seen.insert(key).inserted, !firstLook { fresh.append((event, chat)) }
            }
            // A chat that just started waiting for you
            if chat.status == .needsInput, needed.insert(chat.id).inserted, !firstLook {
                let why = chat.waiting.isEmpty ? "Waiting for your OK" : chat.waiting
                showCard(title: "⏰ \(chat.title) needs you", body: why, color: Status.needsInput.color,
                         link: chat.link, seconds: 20)
                notify(title: "⏰ \(chat.title) needs you", body: why, link: chat.link, silent: true)
                playNeedsSound()
            }
            if chat.status != .needsInput { needed.remove(chat.id) }
        }
        firstLook = false

        if !fresh.isEmpty {
            view.unread += fresh.count
            // A card beside Mochi for every new thing, oldest first so the newest lands on top
            for (event, chat) in fresh.sorted(by: { ($0.0.at ?? 0) < ($1.0.at ?? 0) }) {
                let color = event.text == "Stopped" ? Status.blocked.color : chat.status.color
                showCard(title: event.headline(chat.title), body: event.summary, color: color, link: chat.link)
            }
            NSSound(named: "Pop")?.play()
        }
        // One Mac notification per new event, oldest first
        for (event, chat) in fresh.sorted(by: { ($0.0.at ?? 0) < ($1.0.at ?? 0) }) {
            notify(title: event.headline(chat.title), body: event.summary, link: chat.link)
        }
    }

    /// A card when usage passes 80% or reaches 100% of the 5-hour window or the week
    func checkUsage() {
        guard let now = Usage.read() else { return }
        let isFirst = usage == nil
        usage = now
        view.usage = now
        func level(_ percent: Int) -> Int { percent >= 100 ? 100 : percent >= 80 ? 80 : 0 }
        let five = level(now.fiveHour), week = level(now.week)
        if isFirst { warnedFiveHour = five; warnedWeek = week; wasBlocked = now.blocked != nil; return } // no warning for what was already so at launch
        // You ran out: say when you can continue
        if let back = now.backText, !wasBlocked {
            showCard(title: "⏳ \(now.blocked?.what ?? "Limit") reached", body: back,
                     color: Usage.color(100), link: nil, seconds: 30)
            warnedFiveHour = max(warnedFiveHour, five); warnedWeek = max(warnedWeek, week)
        } else if five > warnedFiveHour, five < 100 {
            showCard(title: "⚠️ 5-hour usage at \(now.fiveHour)%", body: "Week: \(now.week)% used",
                     color: Usage.color(now.fiveHour), link: nil, seconds: 15)
        } else if week > warnedWeek, week < 100 {
            showCard(title: "⚠️ Weekly usage at \(now.week)%",
                     body: "5-hour window: \(now.fiveHour)% used", color: Usage.color(now.week), link: nil, seconds: 15)
        }
        // The limit lifted: you can continue
        if wasBlocked, now.blocked == nil {
            showCard(title: "✅ Claude is back", body: "Your usage reset. You can continue!",
                     color: Status.ready.color, link: nil, seconds: 30)
            NSSound(named: "Glass")?.play()
        }
        wasBlocked = now.blocked != nil
        warnedFiveHour = five < warnedFiveHour ? five : max(warnedFiveHour, five) // a new window starts the warnings over
        warnedWeek = week < warnedWeek ? week : max(warnedWeek, week)
    }

    /// Click the usage label: shows the numbers Mochi already has at once, then refreshes them
    func showUsageDetails() {
        if let known = Usage.read() { usage = known; view.usage = known }
        renderUsagePanel(fresh: false, updating: true)
        refreshUsageQuietly { [weak self] ok in
            self?.renderUsagePanel(fresh: ok, updating: false)
        }
    }

    /// Asks Claude for usage in the background. Skipped if the last check was under 30 seconds ago,
    /// so a flurry of clicks never starts a flurry of checks.
    func refreshUsageQuietly(_ done: ((Bool) -> Void)? = nil) {
        if usageBusy { done?(false); return }
        if let last = usageCheckedAt, Date().timeIntervalSince(last) < 30 {
            done?(true)
            return
        }
        usageBusy = true
        refreshUsageFromClaude { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.usageBusy = false
                if ok { self.usageCheckedAt = Date() }
                if let fresh = Usage.read() { self.usage = fresh; self.view.usage = fresh }
                self.view.needsDisplay = true
                done?(ok)
            }
        }
    }

    /// The glass panel: both limits as bars, when each resets, and how fresh the reading is
    func renderUsagePanel(fresh: Bool, updating: Bool = false) {
        guard let usage else {
            say("No usage reading yet. Send a message and I'll get one.", color: Status.idle.color)
            return
        }
        let worst = max(usage.fiveHour, usage.week)
        let clock = DateFormatter()
        clock.dateFormat = "h:mm a"
        let when = clock.string(from: Date(timeIntervalSince1970: usage.at / 1000))

        func window(_ name: String, _ percent: Int, _ resets: Date?) -> [Line] {
            let reset = resets.flatMap { Usage.until($0) }.map { "resets in \($0)" } ?? "reset time unknown"
            return [
                Line(text: "\(name)   \(Usage.bar(percent))   \(percent)%", bold: true, color: Usage.color(percent)),
                Line(text: reset, indent: 14, dim: true),
            ]
        }

        var lines = [Line(text: worst >= 100 ? "Out of usage" : worst >= 90 ? "Almost out of usage" : "Your usage",
                          bold: true, color: Usage.color(worst))]
        lines += window("5-hour", usage.fiveHour, usage.fiveHourResets)
        lines += window("Week  ", usage.week, usage.weekResets)
        if let back = usage.backText {
            lines.append(Line(text: "⏳ \(back)", bold: true, color: Usage.color(100)))
        }
        let status = updating ? "Updating… · last read \(when)" : fresh ? "Just checked · \(when)" : "Couldn't check now · last read \(when)"
        lines.append(Line(text: status, dim: true))
        bubbleView.lines = lines
        bubbleView.accent = Usage.color(worst)
        showBubble()
    }

    /// A notification card beside Mochi; it fades out on its own after a while
    func showCard(title: String, body: String, color: NSColor, link: String?, seconds: Double = 8) {
        let panel = floatingPanel(size: CardView.size)
        panel.hasShadow = false // the glass draws its own soft edge
        let card = CardView(title: title, body: body, accent: color)
        let glass = glassBackground(for: card, tint: color)
        card.onOpen = { [weak self, weak panel] in
            openChat(link)
            if let panel { self?.dismiss(panel) }
        }
        card.onClose = { [weak self, weak panel] in if let panel { self?.dismiss(panel) } }
        panel.contentView = glass
        panel.alphaValue = 0

        cards.insert(panel, at: 0)
        while cards.count > Self.maxCards { dismiss(cards[cards.count - 1]) }
        placeCards()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }

        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self, weak panel] _ in
            if let panel { self?.dismiss(panel) }
        }
    }

    /// macOS Liquid Glass behind a card, the same glass the system's own notifications use,
    /// lightly tinted by the card's colour
    func glassBackground(for card: CardView, tint: NSColor) -> NSView {
        let glass = makeGlass(size: CardView.size, content: card, radius: 18)
        tintGlass(glass, tint)
        return glass
    }

    /// Liquid Glass holding a view; frosted glass on Macs too old for it
    func makeGlass(size: NSSize, content: NSView, radius: CGFloat) -> NSView {
        let frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = radius
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true } // it responds as the pointer moves over it
            glass.contentView = content
            return glass
        }
        let frosted = NSVisualEffectView(frame: frame)
        frosted.material = .hudWindow
        frosted.blendingMode = .behindWindow
        frosted.state = .active
        frosted.wantsLayer = true
        frosted.layer?.cornerRadius = radius
        frosted.layer?.masksToBounds = true
        content.frame = frame
        content.autoresizingMask = [.width, .height]
        frosted.addSubview(content)
        return frosted
    }

    /// A faint wash of colour through the glass
    func tintGlass(_ view: NSView, _ color: NSColor) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.tintColor = color.withAlphaComponent(0.12)
        }
    }

    func dismiss(_ panel: NSPanel) {
        guard let index = cards.firstIndex(of: panel) else { return }
        cards.remove(at: index)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
        placeCards()
    }

    /// The chat list (when open) and the cards stack beside Mochi as one block, the list nearest her,
    /// then the newest card. Above her when there is room, otherwise below; the whole block stays on screen
    func placeCards() {
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 12 // room between cards, so their glass edges never touch
        var stack: [NSPanel] = cards
        if bubble.isVisible { stack.insert(bubble, at: 0) }
        guard !stack.isEmpty else { return }
        let heights = stack.map { $0.frame.height }
        let stackHeight = heights.reduce(0, +) + CGFloat(stack.count - 1) * gap

        // Above Mochi when there is room, otherwise below; the one with more room wins
        let roomAbove = screen.maxY - window.frame.maxY - 4
        let roomBelow = window.frame.minY - screen.minY - 4
        let goAbove = roomAbove >= stackHeight || roomAbove >= roomBelow

        var bottom = goAbove ? window.frame.maxY + 2 : window.frame.minY - 2 - stackHeight
        bottom = min(max(bottom, screen.minY + 4), screen.maxY - 4 - stackHeight)

        // Above Mochi the nearest item sits lowest; below her it sits highest
        var cursor = goAbove ? bottom : bottom + stackHeight
        for (panel, height) in zip(stack, heights) {
            let width = panel.frame.width
            let x = min(max(window.frame.midX - width / 2, screen.minX + 4), screen.maxX - width - 4)
            let y = goAbove ? cursor : cursor - height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            cursor = goAbove ? cursor + height + gap : cursor - height - gap
        }
    }

    /// A notification in the corner of the screen and in Notification Center
    func notify(title: String, body: String, link: String?, silent: Bool = false) {
        guard macNotifications else { return }
        if notificationsUnavailable {
            let script = "display notification \(appleScriptString(body)) with title \(appleScriptString("Mochi · " + title))"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent ? nil : .default // her own sound plays instead when a chat needs you
        if let link { content.userInfo = ["link": link] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Show the banner even though Mochi is the app in front
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    /// Clicking a Mochi notification opens that chat in Claude
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        openChat(response.notification.request.content.userInfo["link"] as? String)
        done()
    }

    /// A speech bubble above her for a few seconds
    func say(_ text: String, color: NSColor, link: String? = nil) {
        say([Line(text: text, link: link)], color: color)
    }

    /// A bubble with several lines, up for longer when there is more to read
    func say(_ lines: [Line], color: NSColor, seconds: Double = 6) {
        bubbleView.lines = lines
        bubbleView.accent = color
        showBubble()
        hideBubble?.invalidate()
        hideBubble = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.bubble.orderOut(nil)
            self?.placeCards()
        }
    }

    /// Click Mochi: every project and chat, what it is doing, and its latest news; click the list to close it
    func toggleNotifications() {
        if bubble.isVisible { bubble.orderOut(nil); placeCards(); return }
        hideBubble?.invalidate()
        view.unread = 0

        let open = chats.filter(\.isOpen).count
        var lines = [Line(text: chats.isEmpty
                              ? "Mochi · no Claude chats yet"
                              : "\(currentLook.name ?? "Mochi") · \(open) open chat\(open == 1 ? "" : "s") · \(view.status.label)",
                          bold: true, color: view.status.color)]
        if let usage {
            let worst = max(usage.fiveHour, usage.week)
            lines.append(Line(text: "Usage  " + usage.line, color: Usage.color(worst)))
            if let back = usage.backText {
                lines.append(Line(text: "⏳ \(back)", bold: true, color: Usage.color(100)))
            }
        }
        if chats.isEmpty {
            lines.append(Line(text: "Start a Claude chat and I'll tell you how it goes!", dim: true))
        }

        // Open chats first, the most urgent on top, then the most recent
        let sorted = chats.sorted {
            if $0.isOpen != $1.isOpen { return $0.isOpen }
            if $0.isRecent != $1.isRecent { return $0.isRecent }
            if $0.status.urgency != $1.status.urgency { return $0.status.urgency > $1.status.urgency }
            return $0.updatedAt > $1.updatedAt
        }
        for chat in sorted {
            let state = chat.isOpen ? chat.status.label : "Closed"
            lines.append(Line(text: "● \(clip(chat.title, 32)) · \(state) · \(ago(chat.updatedAt))\(chat.link == nil ? "" : "  ↗")",
                              bold: true, color: chat.isOpen ? chat.status.color : .secondaryLabelColor,
                              link: chat.link))
            if chat.status == .needsInput, !chat.waiting.isEmpty {
                lines.append(Line(text: "⏰ \(clip(chat.waiting, 52))", color: Status.needsInput.color, indent: 14, link: chat.link))
            }
            let latest = chat.log.sorted { ($0.at ?? 0) > ($1.at ?? 0) }
            if latest.isEmpty {
                lines.append(Line(text: "Nothing yet", indent: 14, dim: true))
            }
            for (i, event) in latest.enumerated() {
                let took = event.seconds.map { " · \($0)s" } ?? ""
                lines.append(Line(text: "\(icons[event.kind] ?? "•") \(clip(event.summary, 48))\(took) · \(ago(event.at))", indent: 14,
                                  dim: i > 0, link: chat.link))
            }
        }

        if chats.contains(where: { $0.link != nil }) {
            lines.append(Line(text: "Click a chat to open it in Claude", dim: true))
        }
        let total = chats.reduce(0) { $0 + $1.log.count }
        if total > 0 { lines[0] = Line(text: lines[0].text + " · \(total) notification\(total == 1 ? "" : "s")", bold: true, color: lines[0].color) }
        bubbleView.lines = lines
        bubbleView.accent = view.status.color
        showBubble()
    }

    func showBubble() {
        let size = bubbleView.fittingSize(maxWidth: 460)
        // The lines take their full height; the bubble stops growing and scrolls past the cap
        bubble.setContentSize(NSSize(width: size.width + 8, height: min(size.height, bubbleMaxHeight) + 8))
        bubbleView.frame = NSRect(origin: .zero, size: size)
        bubbleFrame.accent = bubbleView.accent
        tintGlass(bubbleGlass, bubbleView.accent)
        bubbleView.scroll(.zero) // start at the top, the newest
        bubbleView.needsDisplay = true
        bubble.invalidateCursorRects(for: bubbleView)
        bubble.orderFrontRegardless()
        placeCards()
    }

    /// The chat list and the cards share one place beside Mochi, so they never cover each other
    func placeBubble() { placeCards() }

    func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        if let usage = Usage.read() {
            menu.addItem(withTitle: "Usage: 5-hour \(usage.fiveHour)% · week \(usage.week)% (\(ago(usage.at)))", action: nil, keyEquivalent: "").isEnabled = false
            if let back = usage.backText { menu.addItem(withTitle: "⏳ \(back)", action: nil, keyEquivalent: "").isEnabled = false }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Show notifications", action: #selector(menuNotifications), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Move to bottom-right corner", action: #selector(menuReset), keyEquivalent: "").target = self
        let skinItem = menu.addItem(withTitle: "Skin", action: nil, keyEquivalent: "")
        let skinMenu = NSMenu()
        for (i, skin) in skins.enumerated() {
            let item = skinMenu.addItem(withTitle: skin.name, action: #selector(menuPickSkin(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == skinIndex ? .on : .off
        }
        skinItem.submenu = skinMenu
        let toggle = menu.addItem(withTitle: "Also show Mac notifications (top-right corner)", action: #selector(menuToggleNotifications), keyEquivalent: "")
        toggle.target = self
        toggle.state = macNotifications ? .on : .off
        let soundItem = menu.addItem(withTitle: "Sound when a chat needs you", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        for name in Self.sounds + ["None"] {
            let item = soundMenu.addItem(withTitle: name, action: #selector(menuPickSound(_:)), keyEquivalent: "")
            item.target = self
            item.state = name == needsSound ? .on : .off
        }
        soundItem.submenu = soundMenu
        let login = menu.addItem(withTitle: "Open at login", action: #selector(menuToggleLogin), keyEquivalent: "")
        login.target = self
        login.state = opensAtLogin ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Mochi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func menuToggleNotifications() { macNotifications.toggle() }

    @objc func menuToggleLogin() { setOpensAtLogin(!opensAtLogin) }

    /// Puts on the chosen skin at once and remembers it
    @objc func menuPickSkin(_ item: NSMenuItem) {
        skinIndex = item.tag
        view.needsDisplay = true
    }

    /// Picks the "needs you" sound and plays it once so you hear it
    @objc func menuPickSound(_ item: NSMenuItem) {
        needsSound = item.title
        playNeedsSound()
    }

    @objc func menuNotifications() { if !bubble.isVisible { toggleNotifications() } }

    @objc func menuReset() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        window.setFrameOrigin(NSPoint(x: screen.maxX - 150, y: screen.minY + 40))
        UserDefaults.standard.removeObject(forKey: "origin")
        placeBubble()
    }
}

/// Text quoted for AppleScript
func appleScriptString(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// `Mochi --refresh-usage` asks Claude for fresh usage, saves it, prints it, then quits
if CommandLine.arguments.contains("--refresh-usage") {
    let waiting = DispatchSemaphore(value: 0)
    var ok = false
    refreshUsageFromClaude { ok = $0; waiting.signal() }
    waiting.wait()
    print(ok ? "Refreshed" : "Could not refresh")
    if let usage = Usage.read() {
        print("Usage  " + usage.line)
        if let back = usage.backText { print("⏳ " + back) }
    }
    exit(0)
}

// `Mochi --usage` prints the plan usage she shows, then quits
if CommandLine.arguments.contains("--usage") {
    if let usage = Usage.read() {
        print("Usage  " + usage.line)
        if let back = usage.backText { print("⏳ " + back) }
    } else {
        print("No usage saved by the Claude app yet")
    }
    exit(0)
}

// `Mochi --chats` prints every chat she sees, then quits (for checking from a terminal)
if CommandLine.arguments.contains("--chats") {
    for chat in readChats().sorted(by: { $0.updatedAt > $1.updatedAt }) {
        let latest = chat.log.max(by: { ($0.at ?? 0) < ($1.at ?? 0) })
        print("\(chat.isRecent ? "●" : "○") \(clip(chat.title, 30).padding(toLength: 30, withPad: " ", startingAt: 0)) \(chat.status.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(ago(chat.updatedAt).padding(toLength: 4, withPad: " ", startingAt: 0)) \(latest.map { clip($0.summary, 50) } ?? "")")
    }
    exit(0)
}

// `Mochi --login-status` prints whether she opens at login, then quits (for checking from a terminal)
if CommandLine.arguments.contains("--login-status") {
    let names: [SMAppService.Status: String] = [
        .enabled: "on", .notRegistered: "off", .requiresApproval: "waiting for your approval", .notFound: "not found",
    ]
    print("Open at login: \(names[SMAppService.mainApp.status] ?? "unknown")")
    exit(0)
}

let app = NSApplication.shared
let delegate = Mochi()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon, no menu bar: just Mochi
app.run()
