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
import AVFoundation
import Carbon
import ServiceManagement
import Speech
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
    /// The tool call waiting for your OK, and when it started waiting: what Allow and Deny answer
    let requestId: String?
    let askedAt: Double?
    /// The whole of what the tool call does, in a line: the full command or path
    let detail: String?
    /// The session's permission mode as the plugin last saw it: 'auto' when Auto is on
    let mode: String?
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
    /// The tool call waiting for your OK, and when it started waiting, for Allow and Deny here
    var requestId = ""
    var askedAt: Double = 0
    var detail = ""
    /// The session's permission mode: 'auto' when Auto is on
    var mode = ""
    /// The chat's plugin can switch modes (Accept edits, Auto); a chat started before that plugin cannot
    var canSwitchMode = false
    var isOpen: Bool { status != .ended }
}

/// Of the chats waiting for your OK, the one that has waited longest
func oldestWaiting(_ chats: [Chat]) -> Chat? {
    func since(_ chat: Chat) -> Double { chat.askedAt > 0 ? chat.askedAt : chat.updatedAt }
    return chats.filter { $0.status == .needsInput && $0.isOpen && $0.isRecent }.min { since($0) < since($1) }
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

/// Each chat's own colour, the same on every launch: a dot on its cards and its line in the list
func chatColor(_ id: String) -> NSColor {
    var hash: UInt32 = 2166136261 // FNV-1a, steady across launches (Swift's hashValue is not)
    for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
    return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.65, brightness: 0.9, alpha: 1)
}

/// Draws a chat's colour dot, 8 points wide, centred on a point
func drawDot(_ color: NSColor, at center: NSPoint) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
}

/// Deletes the .json files in a folder that have not been changed for `days` days. Returns how many it deleted.
@discardableResult
func pruneOldFiles(in folder: URL, olderThan days: Double) -> Int {
    let fm = FileManager.default
    let cutoff = Date().addingTimeInterval(-days * 24 * 3600)
    let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    var deleted = 0
    for url in files where url.pathExtension == "json" {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified < cutoff else { continue }
        if (try? fm.removeItem(at: url)) != nil { deleted += 1 }
    }
    return deleted
}

/// Tools that only look at things: a request for these is not shown as a card, and does not ring
let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "TodoWrite", "ToolSearch"]
/// Commands that only look at things, and the git commands that do
let readOnlyCommands: Set<String> = ["ls", "cat", "head", "tail", "grep", "rg", "find", "pwd", "echo", "wc", "which",
                                     "stat", "file", "diff", "tree", "du", "df", "date", "whoami", "type"]
let readOnlyGit: Set<String> = ["status", "log", "diff", "show", "branch", "remote"]

/// Whether a request needs you, judged from what Claude is waiting to do (the same words as its card):
/// a command or tool that changes something does; one that only looks does not. Questions always do.
func needsYou(waiting: String) -> Bool {
    if waiting.hasPrefix("Run: ") {
        let words = waiting.dropFirst(5).split(separator: " ").map(String.init)
        guard let first = words.first else { return true }
        if readOnlyCommands.contains(first) { return false }
        if first == "git", words.count > 1, readOnlyGit.contains(words[1]) { return false }
        return true
    }
    if waiting.hasPrefix("Use ") {
        return !readOnlyTools.contains(String(waiting.dropFirst(4)))
    }
    return true
}

/// The kinds of thing Mochi may pop up for: a chat that needs your OK, finished work, a usage warning, or one of her thoughts
enum Notice { case approval, finished, usage, thought }

/// Whether a notice may pop up. With "only tell me when something needs my approval" on, approvals and her
/// thoughts (such as how long is left in your 5-hour window) still pop up; finished work and usage warnings do not
func noticeAllowed(_ notice: Notice, onlyApprovals: Bool) -> Bool {
    notice == .approval || notice == .thought || !onlyApprovals
}

/// Whether she is quiet at `now` (seconds since 1970): quiet until the time she was set to, and never when that is 0
func quietAt(until: Double, now: Double) -> Bool { now < until }

/// Whether a chat last active at `updated` (milliseconds) is in her list: any chat from the last seven days, the same as the tidying
func isListed(updated: Double, now: Double) -> Bool { now - updated < 7 * 24 * 3600 * 1000 }

/// Quiet with no end: she stays quiet until you turn her sounds back on (1 January 2100, seconds since 1970)
let quietForever: Double = 4_102_444_800

/// The menu line that shows when she stops being quiet: "until 14:05", or no time at all when she is quiet until you turn her back on
func quietEndsText(until: Double) -> String {
    until >= quietForever ? "" : Date(timeIntervalSince1970: until).formatted(date: .omitted, time: .shortened)
}

/// Which group a chat sits in on her list: 0 running now, 1 needs you, 2 finished, 3 resting
func listGroup(_ status: Status) -> Int {
    switch status {
    case .running: return 0
    case .needsInput, .blocked: return 1
    case .ready: return 2
    default: return 3
    }
}

/// A chat approving on its own: running, in Auto mode. Finished chats in Auto are not counted
func approvingOnItsOwn(_ chat: Chat) -> Bool {
    chat.isOpen && chat.status == .running && chat.mode == "auto"
}

/// The mode a chat is in: the Claude app's own record when it has one, since the plugin's report only
/// carries the mode after a permission request
func effectiveMode(app: String?, report: String?) -> String {
    if let app, !app.isEmpty { return app }
    return report ?? ""
}

/// Whether a chat in the Claude app had activity in the last two minutes, so it counts as running
func isActiveNow(updated: Double, now: Double) -> Bool { now - updated < 2 * 60 * 1000 }

/// A chat with the plugin loaded: running when it was active just now, unless it is waiting for you; otherwise its own status
func liveStatus(_ reported: Status, activeNow: Bool) -> Status {
    reported != .needsInput && activeNow ? .running : reported
}

/// A chat that stopped goes back to normal after ten minutes, so Mochi does not stay grey for a chat nobody is watching
func settledStatus(_ status: Status, updated: Double, now: Double) -> Status {
    status == .blocked && now - updated >= 10 * 60 * 1000 ? .ready : status
}

/// How many of a chat's news lines show: only the latest, unless the chat is expanded
func listShownEvents(total: Int, expanded: Bool) -> Int { expanded ? total : min(total, 1) }

/// The list's heading: her name, and how many chats need you
func boardTitle(needing: Int) -> String {
    switch needing {
    case 0: return "Mochi"
    case 1: return "Mochi · 1 waiting"
    default: return "Mochi · \(needing) waiting"
    }
}

/// The line naming the chats running right now
func runningText(titles: [String]) -> String {
    titles.isEmpty ? "Nothing running right now" : "Running: " + titles.map { clip($0, 32) }.joined(separator: ", ")
}

/// The line naming the chat that finished most recently, and when
func finishedText(title: String?, updated: Double?) -> String {
    guard let title, let updated else { return "Nothing finished lately" }
    return "Finished: \(clip(title, 32)) · \(ago(updated))"
}

/// The word a chat's box gives its state: waiting chats say "Waiting", never "Needs you"
func listStateLabel(_ status: Status) -> String {
    status == .needsInput ? "Waiting" : status.label
}

/// The line under the heading: the chats approving on their own, or else the open chats
func boardSubtitle(approving: Int, open: Int) -> String {
    if approving > 0 { return "\(approving) chat\(approving == 1 ? "" : "s") approving on their own" }
    return "\(open) open chat\(open == 1 ? "" : "s")"
}

/// Whether a group is listed even when empty: only Running now, so it is always at the top of the list
func groupAlwaysShown(_ index: Int) -> Bool { index == 0 }

/// How many finished chats her list shows: only the latest ten
let finishedLimit = 10

/// The newest items first, at most `limit` of them
func recentFirst<T>(_ items: [T], updated: (T) -> Double, limit: Int) -> [T] {
    Array(items.sorted { updated($0) > updated($1) }.prefix(limit))
}

/// The plugin's reports never delete themselves: a chat's report goes after a week untouched, and its answer
/// file after two weeks, so Mochi's files stay small
func pruneOldSessions() {
    pruneOldFiles(in: sessionsFolder, olderThan: 7)
    pruneOldFiles(in: answersFolder, olderThan: 14)
}

let icons = ["turn": "✓", "helper": "•", "task": "⚙", "routine": "⏰", "message": "✉"]
let sessionsFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/mochi/sessions")
/// Mochi's answer to each chat's Allow or Deny, one file per chat
let answersFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/mochi/answers")
/// The plugin's side of Allow and Deny: Mochi's presence, and the answers she writes for a chat
let mochiFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/mochi")

/// Whole seconds left to answer a card: the request was made at askedAt (milliseconds), the window is in milliseconds
func answerSecondsLeft(askedAt: Double, now: Double, window: Double) -> Int {
    max(0, Int(ceil((askedAt + window - now) / 1000)))
}

/// The approval keys to list in the menu for the chat a key would answer: none without a card, the allow and
/// deny keys for any card, and the mode keys only when that chat can switch modes
func approvalShortcutLines(_ waiting: Chat?) -> [String] {
    guard let waiting else { return [] }
    var lines = ["Allow    ⌃⌥1", "Deny    ⌃⌥2"]
    if waiting.canSwitchMode { lines += ["Accept edits    ⌃⌥3", "Auto    ⌃⌥4"] }
    return lines
}

/// Which chat a key answers. The menu test's pretend request, when its card shows, so a test never answers a
/// real chat. Otherwise the one chat whose card shows, and none when several do: a key could then answer a
/// chat you have not read. `waiting` is how many cards show.
func keyTarget(_ chats: [Chat], showing ids: Set<String>, testID: String?) -> (chat: Chat?, waiting: Int) {
    let waiting = chats.filter { !$0.requestId.isEmpty && ids.contains($0.requestId) }
    if let testID, let test = waiting.first(where: { $0.requestId == testID }) { return (test, 1) }
    return (waiting.count == 1 ? waiting[0] : nil, waiting.count)
}

/// Writes a small JSON file in one go, so the plugin never reads half of it
/// A line in ~/.claude/mochi/mochi.log, with the time, so a failed step can be found afterwards.
/// The log is started afresh when it passes 200 KB.
func mochiLog(_ text: String) {
    let url = mochiFolder.appendingPathComponent("mochi.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 200_000 {
        try? FileManager.default.removeItem(at: url)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

func writeJSON(_ object: [String: Any], to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: object) { try? data.write(to: url, options: .atomic) }
}

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
    /// The mode the Claude app has the chat in: "default", "acceptEdits", "auto" and so on
    let permissionMode: String?
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
              now - (report.updatedAt ?? 0) < 12 * 3600 * 1000,
              !([.idle, .ended].contains(status) && (report.log ?? []).isEmpty) // resting or ended, nothing to report: left out
        else { continue }
        let id = url.deletingPathExtension().lastPathComponent
        live[id] = Chat(id: id, title: report.title ?? "Claude",
                        status: settledStatus(status, updated: report.updatedAt ?? 0, now: now), log: report.log ?? [],
                        updatedAt: report.updatedAt ?? 0, link: report.link, waiting: report.waiting ?? "",
                        isRecent: now - (report.updatedAt ?? 0) < recent,
                        requestId: report.requestId ?? "", askedAt: report.askedAt ?? 0, detail: report.detail ?? "",
                        mode: report.mode ?? "", canSwitchMode: report.mode != nil)
    }

    var chats: [Chat] = []
    for session in readAppSessions() where session.isArchived != true {
        let updated = session.lastActivityAt ?? 0
        guard isListed(updated: updated, now: now) else { continue }
        let link = "claude://code/continue?session=\(session.sessionId)&source=mochi"
        let title = session.title ?? "Claude chat"

        // A chat with the mod loaded: its live status, under the app's title
        if let cli = session.cliSessionId, let mine = live.removeValue(forKey: cli) {
            // A busy agent may not report "working", so a chat active just now counts as running, unless it waits for you
            chats.append(Chat(id: mine.id, title: title, status: liveStatus(mine.status, activeNow: isActiveNow(updated: updated, now: now)), log: mine.log,
                              updatedAt: max(mine.updatedAt, updated), link: mine.link ?? link,
                              waiting: mine.waiting, isRecent: mine.isRecent,
                              requestId: mine.requestId, askedAt: mine.askedAt, detail: mine.detail,
                              mode: effectiveMode(app: session.permissionMode, report: mine.mode), canSwitchMode: mine.canSwitchMode))
            continue
        }

        // Any other chat: the app's own summary of its last turn
        let summary = session.postTurnSummary
        let needs = summary?.needs_action ?? ""
        let category = summary?.status_category ?? ""
        // Waiting for you comes first; otherwise a chat active in the last couple of minutes is running
        let status: Status = !needs.isEmpty ? .needsInput
            : isActiveNow(updated: updated, now: now) ? .running
            : category == "blocked" ? settledStatus(.blocked, updated: updated, now: now)
            : category == "completed" ? .ready
            : .idle
        var log: [Event] = []
        if let summary, let detail = summary.status_detail, !detail.isEmpty {
            let text = !needs.isEmpty ? "Needs you" : category == "blocked" ? "Stopped" : "Done"
            log.append(Event(kind: "turn", text: text, detail: needs.isEmpty ? detail : needs, seconds: nil, at: updated))
        }
        // A chat that is resting with nothing to report is left out: its link is not one Mochi can trust
        if status == .idle && log.isEmpty { continue }
        chats.append(Chat(id: session.sessionId, title: title, status: status, log: log, updatedAt: updated,
                          link: link, waiting: needs, isRecent: now - updated < recent,
                          mode: effectiveMode(app: session.permissionMode, report: "")))
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
/// Set when a skin is picked from the right-click menu. Then that skin's colours win over a body colour painted in Mochi Studio
var skinPicked: Bool {
    get { UserDefaults.standard.bool(forKey: "skinPicked") }
    set { UserDefaults.standard.set(newValue, forKey: "skinPicked") }
}
/// Her body colour: the picked skin's, unless Mochi Studio paints a body and no skin was picked since
func bodyColour(look: MochiLook, skin: Skin, picked: Bool) -> NSColor {
    if !picked, let body = look.bodyColor { return body }
    return skin.face
}
var palette: [Character: NSColor] {
    var colours = skins[skinIndex].palette
    colours["B"] = bodyColour(look: currentLook, skin: skins[skinIndex], picked: skinPicked)
    return colours
}
var face: NSColor { bodyColour(look: currentLook, skin: skins[skinIndex], picked: skinPicked) }
var eye: NSColor { skins[skinIndex].eye }

/// How Mochi Studio has dressed her. Missing or unreadable means the defaults.
struct MochiLook: Decodable {
    var body: String?
    var eyes: String?
    var accessory: String?
    var name: String?
    var speed: Double?
    /// Her face, painted in Mochi Studio: 16 rows of 16 letters. Missing or wrong size means the default cat.
    var pixels: [String]?

    /// The grid she draws: the painted one when it is the right size, otherwise the default
    var art: [String] {
        guard let pixels, (8...64).contains(pixels.count), pixels.allSatisfy({ $0.count == pixels.count }) else { return grid }
        return pixels
    }

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

/// Whether she looks tired from your plan usage: from 70%, her eyes are half-closed (no shine)
var usageTired = false

func pixelColor(_ cell: Character, _ status: Status, blinking: Bool) -> NSColor? {
    switch cell {
    case "E": return status == .blocked || blinking || currentLook.eyes == "sleepy" ? face : eye
    case "W": return status == .blocked || blinking || currentLook.eyes == "sleepy" ? face : status == .ready ? eye : .white
    case "e": return status == .ready ? face : eye
    case ".": return nil
    default: return palette[cell]
    }
}

/// Which of the skins a chat wears: the same on every launch, from its id
func chatSkinIndex(_ id: String, count: Int) -> Int {
    guard count > 0 else { return 0 }
    var hash: UInt32 = 2166136261
    for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
    return Int(hash % UInt32(count))
}

/// What a chat's cat wears, chosen in the skin editor. Shell -1 means the skin picked from the chat's id
struct ChatLook: Codable, Equatable {
    var shell = -1
    var hat = 0
    var eyewear = 0
    var extra = 0
}

let shellColours: [(name: String, hex: Int)] = [
    ("Amber", 0xF4A259), ("Coral", 0xEF6F6C), ("Rose", 0xF28DB2), ("Plum", 0x9B5DE5), ("Indigo", 0x5C6BC0),
    ("Sky", 0x4DA8DA), ("Teal", 0x2EC4B6), ("Mint", 0x8FD9B6), ("Lime", 0xA3C94A), ("Slate", 0x7B8494),
]
let hatNames = ["None", "Top hat", "Party hat", "Crown"]
let eyewearNames = ["None", "Glasses", "Sunglasses", "Monocle"]
let extraNames = ["None", "Bow tie", "Scarf", "Bell"]

/// Pieces drawn over the cat, 16 by 16 like her face. K ink, R red, Y gold, P pink; a dot is empty
let hatArt: [[String]] = [
    [],
    ["......KKKK......", "......KKKK......", "......KRRK......", "....KKKKKKKK...."] + Array(repeating: "................", count: 12),
    ["................", ".......YY.......", "......YPPY......", ".....YPYYPY.....", "....YYYYYYYY...."] + Array(repeating: "................", count: 11),
    ["................", "................", "....Y..YY..Y....", "....YYYYYYYY...."] + Array(repeating: "................", count: 12),
]
let eyewearArt: [[String]] = [
    [],
    Array(repeating: "................", count: 6) + ["..KKKK....KKKK..", "..K..KKKKKK..K..", "..K..K....K..K..", "..KKKK....KKKK.."] + Array(repeating: "................", count: 6),
    Array(repeating: "................", count: 6) + ["..KKKK....KKKK..", "..KKKKKKKKKKKK..", "..KKKK....KKKK..", "................"] + Array(repeating: "................", count: 6),
    Array(repeating: "................", count: 6) + ["..........YYYY..", ".........Y....Y.", ".........Y....Y.", "..........YYYY.."] + Array(repeating: "................", count: 6),
]
let extraArt: [[String]] = [
    [],
    Array(repeating: "................", count: 12) + [".....RR....RR...", "......RRKRR....."] + ["................", "................"],
    Array(repeating: "................", count: 12) + ["..KKRRRRRRRRKK..", "..KBRR.......K.."] + ["................", "................"],
    Array(repeating: "................", count: 12) + [".......YY.......", ".......YY......."] + ["................", "................"],
]

/// The skin a chat wears: the one its id picks, with the editor's shell colour over it when one is chosen
func chatSkin(id: String, look: ChatLook) -> Skin {
    let base = skins[chatSkinIndex(id, count: skins.count)]
    guard look.shell >= 0, look.shell < shellColours.count else { return base }
    let shell = NSColor(hex: shellColours[look.shell].hex)
    var palette = base.palette
    palette["B"] = shell
    palette["L"] = shell.blended(withFraction: 0.45, of: .white) ?? shell
    palette["D"] = shell.blended(withFraction: 0.2, of: .black) ?? shell
    palette["K"] = shell.blended(withFraction: 0.65, of: .black) ?? base.palette["K"]
    return Skin(name: base.name, palette: palette, face: shell, eye: NSColor(hex: 0x2B2118))
}

/// A random look for the "Surprise me" button; the same seed gives the same look
func randomChatLook(seed: Int) -> ChatLook {
    var state = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407
    func next(_ count: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(count))
    }
    return ChatLook(shell: next(shellColours.count), hat: next(hatNames.count), eyewear: next(eyewearNames.count), extra: next(extraNames.count))
}

let chatLooksURL = mochiFolder.appendingPathComponent("chatskins.json")
func readChatLooks(from url: URL = chatLooksURL) -> [String: ChatLook] {
    guard let data = try? Data(contentsOf: url), let looks = try? JSONDecoder().decode([String: ChatLook].self, from: data) else { return [:] }
    return looks
}
func saveChatLooks(_ looks: [String: ChatLook], to url: URL = chatLooksURL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(looks) { try? data.write(to: url, options: .atomic) }
}
/// What every chat wears, loaded at launch and saved on each change
var chatLooks: [String: ChatLook] = readChatLooks()

/// Draws 16 by 16 art over a square
private func drawOverlay(_ art: [String], in rect: NSRect) {
    let cell = rect.width / 16
    let ink: [Character: NSColor] = ["K": NSColor(hex: 0x2B2118), "R": NSColor(hex: 0xE5484D), "Y": NSColor(hex: 0xF5C84C), "P": NSColor(hex: 0xFF8FAB)]
    for (y, row) in art.enumerated() {
        for (x, ch) in row.enumerated() {
            guard let color = ink[ch] else { continue }
            color.setFill()
            NSRect(x: rect.minX + CGFloat(x) * cell, y: rect.minY + CGFloat(y) * cell, width: cell, height: cell).insetBy(dx: -0.15, dy: -0.15).fill()
        }
    }
}

/// A chat's small pixel cat: its skin, then its hat, eyewear and extra on top; eyes shut while it rests
func drawCatAvatar(_ skin: Skin, look: ChatLook = ChatLook(), in rect: NSRect, resting: Bool) {
    let cell = rect.width / 16
    for (y, row) in grid.enumerated() {
        for (x, ch) in row.enumerated() {
            let color: NSColor?
            switch ch {
            case ".": color = nil
            case "E", "e": color = resting ? skin.face : skin.eye
            case "W": color = resting ? skin.face : .white
            default: color = skin.palette[ch]
            }
            guard let color else { continue }
            color.setFill()
            NSRect(x: rect.minX + CGFloat(x) * cell, y: rect.minY + CGFloat(y) * cell, width: cell, height: cell).insetBy(dx: -0.15, dy: -0.15).fill()
        }
    }
    if look.extra > 0, look.extra < extraArt.count { drawOverlay(extraArt[look.extra], in: rect) }
    if look.eyewear > 0, look.eyewear < eyewearArt.count { drawOverlay(eyewearArt[look.eyewear], in: rect) }
    if look.hat > 0, look.hat < hatArt.count { drawOverlay(hatArt[look.hat], in: rect) }
}

// MARK: - Mochi's window

let scale: CGFloat = 5
let petSize = CGFloat(16) * scale

final class MochiView: NSView {
    var status: Status = .idle
    var unread = 0
    /// Auto is on in a live chat: she shows gold sparkles around her, and nothing changes in the other modes
    var autoMode = false
    /// Minutes left on a running chat's estimate, for the circle on her left
    var taskMinutesLeft: Int?
    /// The agents running now, for the dots on her left, and where each dot is so a click can find it
    var activeAgents: [AgentRun] = []
    var agentRects: [NSRect] = []
    var originYForDots: CGFloat = 0
    var onAgentsClick: (() -> Void)?
    /// How far a running chat is through its estimate, for the ring round her status badge; nil when none
    var ringFraction: Double?
    /// When a chat last finished, for the green ring
    var finishedAt: Date?
    /// Plan usage, shown as a small label under her
    var usage: Usage?
    /// Where the usage label is drawn, so a click on it can be told from a click on her
    var usagePill: NSRect = .zero
    var onUsageClick: (() -> Void)?
    /// The two buttons under her, and whether Mochi is listening
    var quickRect: NSRect = .zero
    var scrollRect: NSRect = .zero
    /// The diary button: opens "This week"
    var onScroll: (() -> Void)?
    var talkRect: NSRect = .zero
    var recording = false
    /// The cursor is over her, and whether the note box is open
    var nearby = false
    var forceShow = false
    var onQuickNote: (() -> Void)?
    var onTalk: (() -> Void)?
    var tick = 0
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private var grab: NSPoint?
    private var dragged = false
    /// Her status badge: clicking it while a chat needs you opens that chat
    private var badgeRect = NSRect.zero
    var onBadgeClick: (() -> Void)?

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

        // She looks tired from 70% of either window, the same level the label turns orange at
        usageTired = (usage.map { max($0.fiveHour, $0.week) } ?? 0) >= 70

        let originX = (bounds.width - petSize) / 2
        let originY = 46 - lift // the usage label above her, the two buttons below
        ctx.saveGState()
        ctx.translateBy(x: originX + petSize / 2, y: originY + petSize / 2)
        ctx.rotate(by: tilt)
        ctx.translateBy(x: -petSize / 2, y: -petSize / 2)
        drawPixels(currentLook.art, blinking: blinking)
        if usageTired || lowTimeMinutes(resets: usage?.fiveHourResets, now: Date()) != nil {
            // A lid: the top half of each eye in the body colour, so she looks half-closed
            face.setFill()
            for col in [3, 11] { NSRect(x: CGFloat(col) * scale, y: 7 * scale, width: 2 * scale, height: scale / 2).fill() }
        }
        drawAccessory(currentLook.accessory ?? "none")
        ctx.restoreGState()
        if autoMode { drawSparkles(around: NSPoint(x: originX + petSize / 2, y: originY + petSize / 2)) }

        drawBadge(at: NSPoint(x: originX + petSize - 4, y: originY + 6))
        drawProgressRing(at: NSPoint(x: originX + petSize - 4, y: originY + 6))
        originYForDots = originY
        drawAgentDots()
        badgeRect = NSRect(x: originX + petSize - 13, y: originY - 3, width: 18, height: 18)
        if let taskMinutesLeft {
            drawCountCircle(taskMinutesLeft, color: NSColor(hex: 0x0A6CF0), at: NSPoint(x: originX + 4, y: originY + 6))
        }
        if unread > 0 { drawUnread(at: NSPoint(x: originX + 4, y: taskMinutesLeft == nil ? originY + 6 : originY + 24)) }
        if let usage { drawUsage(usage) }
        // The countdown sits on the right end of the usage bar, over its corner
        if let minutesLeft = lowTimeMinutes(resets: usage?.fiveHourResets, now: Date()) {
            drawCountdown(minutesLeft, at: NSPoint(x: usagePill.maxX - 1, y: 16)) // at the right end of the usage bar, on its top edge
        }
        // The two buttons show only when the cursor is near her, or while the note box is open or listening
        if nearby || forceShow || recording {
            drawButtons()
        } else {
            quickRect = .zero
            talkRect = .zero
            scrollRect = .zero
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackHover(self)
    }

    override func mouseEntered(with event: NSEvent) {
        nearby = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        nearby = false
        needsDisplay = true
    }

    /// Two round buttons under her: a quick note to start a session, and talk to Mochi (red while listening)
    private func drawButtons() {
        let y: CGFloat = 142
        let center = bounds.width / 2
        let spread: CGFloat = 36
        quickRect = NSRect(x: center - spread - 13, y: y - 13, width: 26, height: 26)
        talkRect = NSRect(x: center - 13, y: y - 13, width: 26, height: 26)
        scrollRect = NSRect(x: center + spread - 13, y: y - 13, width: 26, height: 26)
        let ink = NSColor(white: 0.25, alpha: 1)
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: quickRect).fill()
        if recording { NSColor(hex: 0xE03131).setFill() } else { NSColor.white.withAlphaComponent(0.92).setFill() }
        NSBezierPath(ovalIn: talkRect).fill()

        // The quick note: a pencil
        ink.setStroke()
        let pencil = NSBezierPath()
        pencil.move(to: NSPoint(x: quickRect.midX - 4, y: quickRect.midY + 4))
        pencil.line(to: NSPoint(x: quickRect.midX + 4, y: quickRect.midY - 4))
        pencil.lineWidth = 2.2
        pencil.lineCapStyle = .round
        pencil.stroke()

        // Talk: a microphone
        (recording ? NSColor.white : ink).setStroke()
        let cx = talkRect.midX, cy = talkRect.midY
        let mic = NSBezierPath(roundedRect: NSRect(x: cx - 3, y: cy - 6, width: 6, height: 9), xRadius: 3, yRadius: 3)
        mic.lineWidth = 1.6
        mic.stroke()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: cx, y: cy + 3))
        stem.line(to: NSPoint(x: cx, y: cy + 6))
        stem.move(to: NSPoint(x: cx - 3, y: cy + 6))
        stem.line(to: NSPoint(x: cx + 3, y: cy + 6))
        stem.lineWidth = 1.6
        stem.lineCapStyle = .round
        stem.stroke()

        // The diary: a sheet with a rolled top, in the same ink
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: scrollRect).fill()
        ink.setStroke()
        let sx = scrollRect.midX, sy = scrollRect.midY
        let sheet = NSBezierPath(roundedRect: NSRect(x: sx - 6, y: sy - 4, width: 12, height: 13), xRadius: 2, yRadius: 2)
        sheet.lineWidth = 1.5
        sheet.stroke()
        let roll = NSBezierPath(roundedRect: NSRect(x: sx - 8, y: sy - 8, width: 16, height: 6), xRadius: 3, yRadius: 3)
        roll.lineWidth = 1.5
        roll.stroke()
        let lines = NSBezierPath()
        lines.move(to: NSPoint(x: sx - 3, y: sy + 1)); lines.line(to: NSPoint(x: sx + 3, y: sy + 1))
        lines.move(to: NSPoint(x: sx - 3, y: sy + 5)); lines.line(to: NSPoint(x: sx + 3, y: sy + 5))
        lines.lineWidth = 1.2
        lines.stroke()
    }

    /// Her face, pixel by pixel. A 16 by 16 face is drawn with smoothed corners and diagonals (four pixels
    /// per square); a finer face is drawn as it was painted.
    private func drawPixels(_ art: [String], blinking: Bool) {
        let n = art.count
        if n != 16 {
            let cell = petSize / CGFloat(n)
            for (y, row) in art.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard var color = pixelColor(ch, status, blinking: blinking) else { continue }
                    if status == .blocked { color = color.blended(withFraction: 0.75, of: .gray) ?? color }
                    color.setFill()
                    NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).insetBy(dx: -0.1, dy: -0.1).fill()
                }
            }
            return
        }
        let rows = art.map { Array($0) }
        let half = scale / 2
        for y in rows.indices {
            for x in rows[y].indices {
                let p = rows[y][x]
                let a = y > 0 ? rows[y - 1][x] : p
                let b = x < rows[y].count - 1 ? rows[y][x + 1] : p
                let c = x > 0 ? rows[y][x - 1] : p
                let d = y < rows.count - 1 ? rows[y + 1][x] : p
                let corners: [Character] = [
                    c == a && c != d && a != b ? a : p,
                    a == b && a != c && b != d ? b : p,
                    d == c && d != b && c != a ? c : p,
                    b == d && b != a && d != c ? d : p,
                ]
                for (i, cell) in corners.enumerated() {
                    guard var color = pixelColor(cell, status, blinking: blinking) else { continue }
                    if status == .blocked { color = color.blended(withFraction: 0.75, of: .gray) ?? color }
                    color.setFill()
                    let sx = CGFloat(x * 2 + i % 2) * half
                    let sy = CGFloat(y * 2 + i / 2) * half
                    NSRect(x: sx, y: sy, width: half, height: half).insetBy(dx: -0.1, dy: -0.1).fill()
                }
            }
        }
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

    /// Gold sparkles around her, drawn only while Auto is on. (x, y) is her centre.
    private func drawSparkles(around center: NSPoint) {
        NSColor(hex: 0xFFC43D).setFill()
        for (dx, dy, size) in [(-58.0, -45.0, 7.0), (50.0, -38.0, 5.0), (-50.0, 20.0, 4.5), (48.0, 30.0, 6.5)] {
            let x = center.x + CGFloat(dx), y = center.y + CGFloat(dy), s = CGFloat(size)
            let star = NSBezierPath()
            star.move(to: NSPoint(x: x, y: y - s))
            star.line(to: NSPoint(x: x + s / 3, y: y - s / 3))
            star.line(to: NSPoint(x: x + s, y: y))
            star.line(to: NSPoint(x: x + s / 3, y: y + s / 3))
            star.line(to: NSPoint(x: x, y: y + s))
            star.line(to: NSPoint(x: x - s / 3, y: y + s / 3))
            star.line(to: NSPoint(x: x - s, y: y))
            star.line(to: NSPoint(x: x - s / 3, y: y - s / 3))
            star.close()
            star.fill()
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
        var words = "5h \(usage.fiveHour)% · \(usage.week)%"
        if let blocked = usage.blocked {
            words = blocked.until.map { "Back \(Usage.clock($0))" } ?? "Limit reached"
        }
        let text = NSAttributedString(string: words, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        // A few points below the top edge, so the rounded ends are not cut off by the window
        let pill = NSRect(x: (bounds.width - size.width) / 2 - 9, y: 20, width: size.width + 18, height: 20)
        usagePill = pill
        Usage.color(max(usage.fiveHour, usage.week)).withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + (pill.height - size.height) / 2))
    }

    /// A blue dot for each agent running now, in a column on her left; a click on them opens the list
    private func drawAgentDots() {
        agentRects = []
        for (i, _) in activeAgents.prefix(4).enumerated() {
            let center = NSPoint(x: 9, y: originYForDots + 14 + CGFloat(i) * 16)
            let pulse = CGFloat(abs(sin(Double(tick) / 6))) * 4
            NSColor(hex: 0x1C7ED6).withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 6 - pulse, y: center.y - 6 - pulse, width: 12 + pulse * 2, height: 12 + pulse * 2)).fill()
            NSColor(hex: 0x1C7ED6).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)).fill()
            agentRects.append(NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20))
        }
    }

    /// A ring round the status badge: blue as a running chat fills its estimate, and green for a minute after one finishes
    private func drawProgressRing(at center: NSPoint) {
        let r: CGFloat = 13
        let circle = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        if ringShowsFinished(finishedAt: finishedAt, now: Date()) {
            let ring = NSBezierPath(ovalIn: circle)
            ring.lineWidth = 3
            NSColor(hex: 0x2F9E44).setStroke()
            ring.stroke()
            return
        }
        guard let fraction = ringFraction else { return }
        let track = NSBezierPath(ovalIn: circle)
        track.lineWidth = 3
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        track.stroke()
        // Points round the circle from the top, clockwise on screen (the view is flipped, so y grows downward)
        let arc = NSBezierPath()
        let steps = max(2, Int(ringSweepDegrees(fraction) / 4))
        for i in 0...steps {
            let angle = (-90 + ringSweepDegrees(fraction) * Double(i) / Double(steps)) * .pi / 180
            let point = NSPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
            if i == 0 { arc.move(to: point) } else { arc.line(to: point) }
        }
        arc.lineWidth = 3
        arc.lineCapStyle = .round
        NSColor(hex: 0x0A6CF0).setStroke()
        arc.stroke()
    }

    /// The countdown to the end of the 5-hour window: a small circle, orange then red, with the minutes left
    private func drawCountdown(_ minutes: Int, at center: NSPoint) {
        drawCountCircle(minutes, color: countdownIsUrgent(minutes) ? NSColor(hex: 0xE03131) : NSColor(hex: 0xF08C00), at: center)
    }

    /// A small coloured circle with a number in it
    private func drawCountCircle(_ minutes: Int, color: NSColor, at center: NSPoint) {
        let r: CGFloat = 9
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)).fill()
        let text = NSAttributedString(string: "\(minutes)", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
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
            if quickRect.insetBy(dx: -4, dy: -4).contains(point) { onQuickNote?() }
            else if talkRect.insetBy(dx: -4, dy: -4).contains(point) { onTalk?() }
            else if scrollRect.insetBy(dx: -4, dy: -4).contains(point) { onScroll?() }
            else if usagePill.insetBy(dx: -4, dy: -4).contains(point) { onUsageClick?() }
            else if agentRects.contains(where: { $0.contains(point) }) { onAgentsClick?() }
            else if status == .needsInput, badgeRect.insetBy(dx: -3, dy: -3).contains(point), let onBadgeClick { onBadgeClick() }
            else { onClick?() }
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
    /// The chat's own colour, as a dot before the line
    var dot: NSColor? = nil
}

/// Lets a view know when the pointer moves over it, even when its window is not in front
func trackHover(_ view: NSView) {
    view.trackingAreas.forEach { view.removeTrackingArea($0) }
    view.addTrackingArea(NSTrackingArea(rect: view.bounds,
                                        options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                        owner: view, userInfo: nil))
}

/// A thin line under text, drawn while the pointer is over a link
func underline(from x: CGFloat, width: CGFloat, y: CGFloat, color: NSColor) {
    color.setStroke()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: y))
    path.line(to: NSPoint(x: x + width, y: y))
    path.lineWidth = 1
    path.stroke()
}

final class BubbleView: NSView {
    var lines: [Line] = []
    /// The line under the pointer, when it is a link
    var hovered: Int?
    var accent: NSColor = .systemBlue
    override var isFlipped: Bool { true }

    static let font = NSFont.systemFont(ofSize: 12)
    static let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let widest = lines.map { line in
            NSAttributedString(string: line.text, attributes: [.font: line.bold ? Self.bold : Self.font]).size().width + line.indent
                + (line.dot == nil ? 0 : 12)
        }.max() ?? 0
        return NSSize(width: min(maxWidth, widest + 24), height: CGFloat(lines.count) * 18 + 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, line) in lines.enumerated() {
            if let dot = line.dot { drawDot(dot, at: NSPoint(x: 12 + line.indent + 4, y: 8 + CGFloat(i) * 18 + 9)) }
            let line = line.dot == nil ? line
                : Line(text: line.text, bold: line.bold, color: line.color, indent: line.indent + 12, dim: line.dim, link: line.link)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let color = line.color ?? (line.dim ? NSColor.secondaryLabelColor : NSColor.labelColor)
            NSAttributedString(string: line.text, attributes: [
                .font: line.bold ? Self.bold : Self.font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]).draw(in: NSRect(x: 12 + line.indent, y: 8 + CGFloat(i) * 18,
                               width: bounds.width - 24 - line.indent, height: 18))
            if i == hovered {
                let width = min(NSAttributedString(string: line.text, attributes: [.font: line.bold ? Self.bold : Self.font]).size().width,
                                bounds.width - 24 - line.indent)
                underline(from: 12 + line.indent, width: width, y: 8 + CGFloat(i) * 18 + 16, color: color)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackHover(self)
    }

    /// Underlines a chat's line while the pointer is over it
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - 8) / 18)
        let link = point.y >= 8 && lines.indices.contains(row) && lines[row].link != nil ? row : nil
        if link != hovered {
            hovered = link
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    /// Clicking a chat's line opens it in Claude; anywhere else closes the bubble
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - 8) / 18)
        if point.y >= 8, lines.indices.contains(row), let link = lines[row].link { openChat(link) }
        window?.orderOut(nil)
    }

    override func resetCursorRects() {
        for (i, line) in lines.enumerated() where line.link != nil {
            addCursorRect(NSRect(x: 0, y: 8 + CGFloat(i) * 18, width: bounds.width, height: 18), cursor: .pointingHand)
        }
    }
}

/// The rounded box behind the bubble; the lines scroll inside it
/// A reset offer: how many resets you have, and the moment you must use them by
struct ResetOffer {
    let count: Int
    let useBy: Date
}

/// Whole days left to use a reset offer, rounding a part day up. Nil once it has passed
func resetOfferDaysLeft(useBy: Date, now: Date) -> Int? {
    let left = useBy.timeIntervalSince(now)
    guard left > 0 else { return nil }
    return Int(ceil(left / 86400))
}

/// Reads "yyyy-mm-dd, count" into an offer, usable until the end of that day. Nil if it does not read
func parseResetOffer(_ text: String, calendar: Calendar = .current) -> ResetOffer? {
    let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 2, let count = Int(parts[1]), count > 0 else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    guard let day = formatter.date(from: parts[0]),
          let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: day) else { return nil }
    return ResetOffer(count: count, useBy: end)
}

/// Whether her three buttons show: when the pointer is within 60 points of her window, and hidden otherwise
func buttonsShowFor(pointer: NSPoint, frame: NSRect) -> Bool {
    frame.insetBy(dx: -60, dy: -60).contains(pointer)
}

/// Reads one line of /usage, such as "Current session: 58% used · resets Oct 19 at 6:40pm". The reset time may be missing
func usageReading(in output: String, line: String) -> (percent: Int, resets: String?)? {
    guard let regex = try? NSRegularExpression(pattern: "\(line): (\\d+)% used(?: · resets ([^\\n]+))?"),
          let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
          let percent = Range(match.range(at: 1), in: output) else { return nil }
    let resets = Range(match.range(at: 2), in: output).map { String(output[$0]) }
    return (Int(output[percent]) ?? 0, resets)
}

/// A colour that follows light or dark mode, for the glass: one value in light, one in dark
func adaptiveColor(_ light: NSColor, _ dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
    }
}

/// Draws one line of text, or only measures it, and returns its width
@discardableResult
func drawLine(_ text: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat,
              align: NSTextAlignment = .left, draw: Bool) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    style.alignment = align
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    if draw { string.draw(in: NSRect(x: x, y: y, width: width, height: font.pointSize + 6)) }
    return string.size().width
}

/// A small rounded button: a filled accent one, or an outlined one
func drawButton(_ rect: NSRect, _ title: String, filled: Bool, draw: Bool) {
    guard draw else { return }
    let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    if filled {
        NSColor.controlAccentColor.setFill()
        path.fill()
    } else {
        path.lineWidth = 0.5
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        path.stroke()
    }
    drawLine(title, .systemFont(ofSize: 12, weight: .medium), filled ? .white : .labelColor,
             x: rect.minX, y: rect.minY + 3, width: rect.width, align: .center, draw: true)
}

/// Whole minutes left in the 5-hour window, only in its last 60 minutes: 60 down to 0. Nil otherwise
func lowTimeMinutes(resets: Date?, now: Date) -> Int? {
    guard let resets else { return nil }
    let left = resets.timeIntervalSince(now)
    guard left > 0, left <= 60 * 60 else { return nil }
    return Int(left / 60)
}

/// A countdown on one chat, from when it started to when it is up
struct ChatTimer {
    let title: String
    let start: Date
    let end: Date
}

/// What a mochi:// link asks for: a countdown on a chat, or stopping one
enum MochiLink: Equatable {
    case countdown(chat: String, minutes: Int)
    case stop(chat: String?)
    case brief(kind: String)
}

/// Reads "mochi://countdown?chat=Redo%20the%20search&minutes=47" or "mochi://stop?chat=..." into a request
func parseMochiLink(_ url: URL) -> MochiLink? {
    guard url.scheme == "mochi", let host = url.host else { return nil }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    switch host {
    case "countdown":
        guard let chat = value("chat"), !chat.isEmpty, let minutes = Int(value("minutes") ?? ""), minutes > 0 else { return nil }
        return .countdown(chat: chat, minutes: minutes)
    case "stop":
        return .stop(chat: value("chat"))
    case "brief":
        // "mochi://brief?kind=morning" or "mochi://brief?kind=evening"; morning when none is given
        return .brief(kind: value("kind") == "evening" ? "evening" : "morning")
    default:
        return nil
    }
}

/// The chat a name means: the open chat whose title contains it, most recent first
func chatNamed(_ name: String, in chats: [Chat]) -> Chat? {
    let key = name.lowercased()
    return chats.filter { $0.isOpen && $0.title.lowercased().contains(key) }.max { $0.updatedAt < $1.updatedAt }
}

/// How long a chat's last finished turn took, in seconds: the estimate for its next run. Nil when none is known
func taskEstimate(_ log: [Event]) -> Int? {
    let recent = log.filter { $0.seconds != nil }.sorted { ($0.at ?? 0) > ($1.at ?? 0) }.prefix(5)
    return recent.compactMap(\.seconds).max()
}

/// The timer line for a running chat: how long it has run, and the time left on its estimate
func taskTimerText(elapsed: Int, estimate: Int?) -> String {
    let ran = max(1, elapsed / 60)
    guard let estimate else { return "Running for \(ran) min · no estimate yet" }
    if elapsed <= estimate {
        return "Running for \(ran) min · about \(max(1, Int(ceil(Double(estimate - elapsed) / 60)))) min left"
    }
    return "Running for \(ran) min"
}

/// How far through its estimate a run is, from 0 to 1
func taskProgress(elapsed: Int, estimate: Int?) -> Double {
    guard let estimate, estimate > 0 else { return 0 }
    return min(1, Double(elapsed) / Double(estimate))
}

/// How far round the ring a fraction goes, in degrees: 0 to 360
func ringSweepDegrees(_ fraction: Double) -> Double {
    min(360, max(0, fraction * 360))
}

/// The window level for the brief: pinned sits above the other floating windows, otherwise the usual floating level
func briefLevel(pinned: Bool) -> NSWindow.Level { pinned ? .statusBar : .floating }

/// Notification cards, the chat list and her thoughts show only while notifications are not hidden
func cardMayShow(hidden: Bool) -> Bool { !hidden }

/// Whether the brief stays on top of other windows; remembered between launches
var briefOnTop: Bool {
    get { UserDefaults.standard.bool(forKey: "briefOnTop") }
    set { UserDefaults.standard.set(newValue, forKey: "briefOnTop") }
}

/// Whether the pointer is close enough to Mochi, or on the brief, to keep the brief showing
func pointerNearBrief(pointer: NSPoint, mochi: NSRect, brief: NSRect, margin: CGFloat) -> Bool {
    mochi.insetBy(dx: -margin, dy: -margin).contains(pointer) || brief.contains(pointer)
}

/// Where a card goes under Mochi: centred on her, below her when there is room, above otherwise, and kept on screen
func briefOrigin(under mochi: NSRect, width: CGFloat, height: CGFloat, screen: NSRect) -> NSPoint {
    let x = min(max(mochi.midX - width / 2, screen.minX + 4), screen.maxX - width - 4)
    var y = mochi.minY - height - 6
    if y < screen.minY + 4 { y = mochi.maxY + 6 }
    return NSPoint(x: x, y: y)
}

/// Whether the ring shows the green "done" state: for a minute after a chat finishes
func ringShowsFinished(finishedAt: Date?, now: Date) -> Bool {
    guard let finishedAt else { return false }
    return now.timeIntervalSince(finishedAt) < 60
}

/// Minutes left on the estimate for Mochi's circle. Nil when there is no estimate, or it has passed
func taskCircleMinutes(elapsed: Int, estimate: Int?) -> Int? {
    guard let estimate, elapsed < estimate else { return nil }
    return max(1, Int(ceil(Double(estimate - elapsed) / 60)))
}

/// The countdown turns red in the last 30 minutes of the 5-hour window, and is orange before that
func countdownIsUrgent(_ minutes: Int) -> Bool { minutes <= 30 }

/// The state of her usage, from the fuller of the two limits
func usageState(worst: Int) -> String {
    worst >= 100 ? "Out of usage" : worst >= 90 ? "Almost out" : worst >= 70 ? "Getting high" : "On track"
}

/// Her usage status box, laid out like the chat list: the state, the two limits as cards with bars, and a footer
/// with the last check and a Refresh button
final class UsagePanelView: NSView {
    static let width: CGFloat = 340
    var usage: Usage?
    /// A reset offer to show in the box, when there is one still open
    var resetOffer: ResetOffer?
    /// True while Claude is being asked for a fresh reading
    var checking = false
    /// The last check, in a few words: "Checked 2:14 PM"
    var footnote = ""
    var onRefresh: (() -> Void)?
    private var refreshRect = NSRect.zero

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The height the box needs, measured the same way it is drawn
    func fittingHeight() -> CGFloat { render(draw: false) }

    override func draw(_ dirtyRect: NSRect) { render(draw: true) }

    @discardableResult
    private func render(draw: Bool) -> CGFloat {
        let pad: CGFloat = 16
        let inner = Self.width - pad * 2
        var y: CGFloat = 14
        guard let usage else {
            drawLine("No usage reading yet. Send a message and I'll get one.", .systemFont(ofSize: 12), .tertiaryLabelColor,
                     x: pad, y: y, width: inner, draw: draw)
            return y + 36
        }

        // The state, in a pill at the right of the title
        let worst = max(usage.fiveHour, usage.week)
        let pillFont = NSFont.systemFont(ofSize: 12)
        drawLine("Your usage", .systemFont(ofSize: 15, weight: .medium), .labelColor, x: pad, y: y, width: inner * 0.6, draw: draw)
        let state = usageState(worst: worst)
        let textWidth = drawLine(state, pillFont, Usage.color(worst), x: 0, y: 0, width: 0, draw: false)
        let pill = NSRect(x: pad + inner - textWidth - 16, y: y, width: textWidth + 16, height: 20)
        if draw {
            Usage.color(worst).withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        }
        drawLine(state, pillFont, Usage.color(worst), x: pill.minX, y: y + 2, width: pill.width, align: .center, draw: draw)
        y += 32

        // A reset offer you can still use: how many, the day to use it by, and the days left
        if let offer = resetOffer, let days = resetOfferDaysLeft(useBy: offer.useBy, now: Date()) {
            let box = NSRect(x: pad, y: y, width: inner, height: 50)
            if draw {
                adaptiveColor(NSColor(hex: 0xFAEEDA), NSColor(hex: 0x4A3510)).setFill()
                NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
                NSColor(hex: 0xEF9F27).setStroke()
                let edge = NSBezierPath(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), xRadius: 12, yRadius: 12)
                edge.lineWidth = 0.5
                edge.stroke()
            }
            let day = DateFormatter()
            day.dateFormat = "EEE, d MMMM"
            let headline = "\(offer.count) reset\(offer.count == 1 ? "" : "s") offer\(offer.count == 1 ? "" : "s") available"
            drawLine(headline, .systemFont(ofSize: 13, weight: .medium), adaptiveColor(NSColor(hex: 0x412402), NSColor(hex: 0xFAEEDA)),
                     x: pad + 12, y: y + 8, width: inner - 24, draw: draw)
            drawLine("Use it before \(day.string(from: offer.useBy)) · \(days) day\(days == 1 ? "" : "s") left",
                     .systemFont(ofSize: 12), adaptiveColor(NSColor(hex: 0x633806), NSColor(hex: 0xF5D9A6)),
                     x: pad + 12, y: y + 27, width: inner - 24, draw: draw)
            y += 60
        }

        // Out of usage: when you can continue
        if let back = usage.backText {
            let box = NSRect(x: pad, y: y, width: inner, height: 48)
            if draw {
                Usage.color(100).withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            }
            drawLine(back, .systemFont(ofSize: 13, weight: .medium), Usage.color(100), x: pad + 10, y: y + 8, width: inner - 20, draw: draw)
            drawLine("Your limit resets then. Chats can continue.", .systemFont(ofSize: 12), Usage.color(100),
                     x: pad + 10, y: y + 26, width: inner - 20, draw: draw)
            y += 56
        }

        // The two limits as cards: the percentage, a bar, and when it resets
        let cardWidth = (inner - 8) / 2
        let limits: [(name: String, percent: Int, resets: Date?)] = [
            ("5-hour", usage.fiveHour, usage.fiveHourResets),
            ("Week", usage.week, usage.weekResets),
        ]
        for (i, limit) in limits.enumerated() {
            let x = pad + CGFloat(i) * (cardWidth + 8)
            if draw {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cardWidth, height: 90), xRadius: 8, yRadius: 8).fill()
            }
            drawLine(limit.name, .systemFont(ofSize: 12), .secondaryLabelColor, x: x + 10, y: y + 10, width: cardWidth - 20, draw: draw)
            drawLine("\(limit.percent)%", .systemFont(ofSize: 18, weight: .medium), .labelColor, x: x + 10, y: y + 26, width: cardWidth - 20, draw: draw)
            if draw {
                let track = NSRect(x: x + 10, y: y + 56, width: cardWidth - 20, height: 4)
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                Usage.color(limit.percent).setFill()
                let filled = track.width * CGFloat(min(100, max(0, limit.percent))) / 100
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: filled, height: 4), xRadius: 2, yRadius: 2).fill()
            }
            let reset = Usage.until(limit.resets).map { "Resets in \($0)" } ?? "Reset time unknown"
            drawLine(reset, .systemFont(ofSize: 11), .tertiaryLabelColor, x: x + 10, y: y + 66, width: cardWidth - 20, draw: draw)
        }
        y += 98

        // The footer: the last check, and Refresh
        if draw {
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: pad, y: y))
            rule.line(to: NSPoint(x: pad + inner, y: y))
            rule.lineWidth = 0.5
            NSColor.labelColor.withAlphaComponent(0.15).setStroke()
            rule.stroke()
        }
        y += 10
        drawLine(footnote, .systemFont(ofSize: 12), .secondaryLabelColor, x: pad, y: y + 3, width: inner - 100, draw: draw)
        refreshRect = NSRect(x: pad + inner - 84, y: y, width: 84, height: 24)
        drawButton(refreshRect, checking ? "Checking…" : "Refresh", filled: false, draw: draw)
        return y + 34
    }

    // A click on Refresh asks for a fresh reading; anywhere else closes the box
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if refreshRect.contains(point) {
            if !checking { onRefresh?() }
            return
        }
        window?.orderOut(nil)
    }
}

/// The morning brief, the 8 PM wrap-up or the agent list: big-number tiles, rows, a week chart and top chats, with a cross to close it
final class BriefView: NSView {
    static let width: CGFloat = 380
    var content = BriefContent()
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func fittingHeight() -> CGFloat { render(draw: false) }
    override func draw(_ dirtyRect: NSRect) { render(draw: true) }

    private var closeRect: NSRect { NSRect(x: bounds.width - 32, y: 16, width: 16, height: 16) }
    /// The pin sits just left of the cross; a pinned brief stays above other windows
    private var pinRect: NSRect { NSRect(x: bounds.width - 56, y: 16, width: 16, height: 16) }
    var pinned = false
    var onPin: (() -> Void)?
    /// The latest-session rows that open a chat, with their links, and the one under the pointer
    private var latestHits: [(NSRect, String)] = []
    private var hovered: Int?
    /// The top-chat rows that open a chat, and the one under the pointer
    private var topHits: [(NSRect, String)] = []
    private var topHovered: Int?
    /// The waiting rows that open a chat, and the one under the pointer
    private var rowHits: [(NSRect, String)] = []
    private var rowHovered: Int?

    /// Duet's plum for small labels, lighter in Dark mode so it still reads on the glass
    private var duetPlum: NSColor { adaptiveColor(NSColor(hex: 0x9C6B84), NSColor(hex: 0xD9A9BE)) }

    @discardableResult
    private func render(draw: Bool) -> CGFloat {
        let pad: CGFloat = 18
        let inner = Self.width - pad * 2
        var y: CGFloat = 16
        if content.duet {
            drawLine(content.date.uppercased(), .systemFont(ofSize: 11, weight: .semibold), duetPlum, x: pad, y: y, width: inner - 30, draw: draw)
            drawLine(content.title, .systemFont(ofSize: 26, weight: .semibold), .labelColor, x: pad, y: y + 16, width: inner - 30, draw: draw)
            y += 58
        } else {
            drawLine(content.title, .systemFont(ofSize: 17, weight: .semibold), .labelColor, x: pad, y: y, width: inner - 120, draw: draw)
            drawLine(content.date, .systemFont(ofSize: 12), .secondaryLabelColor, x: pad, y: y + 3, width: inner - 60, align: .right, draw: draw)
            y += 34
        }
        if draw {
            let pinColour = pinned ? (content.duet ? duetPlum : NSColor.labelColor) : NSColor.tertiaryLabelColor
            let pinSymbol = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "Keep on top")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [pinColour])))
            pinSymbol?.draw(in: pinRect.insetBy(dx: 1, dy: 1))
            let cross = closeRect.insetBy(dx: 3, dy: 3)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: cross.minX, y: cross.minY)); path.line(to: NSPoint(x: cross.maxX, y: cross.maxY))
            path.move(to: NSPoint(x: cross.maxX, y: cross.minY)); path.line(to: NSPoint(x: cross.minX, y: cross.maxY))
            path.lineWidth = 1.6
            (content.duet ? duetPlum : NSColor.secondaryLabelColor).setStroke()
            path.stroke()
        }

        if let headline = content.headline {
            drawLine(headline.big, .systemFont(ofSize: 34, weight: .semibold), .labelColor, x: pad, y: y, width: inner, draw: draw)
            y += 42
            drawLine(headline.sub, .systemFont(ofSize: 12), .secondaryLabelColor, x: pad, y: y, width: inner, draw: draw)
            y += 26
        }

        // The big-number tiles
        if !content.stats.isEmpty {
            let gap: CGFloat = 8
            let width = (inner - gap * CGFloat(content.stats.count - 1)) / CGFloat(content.stats.count)
            for (i, stat) in content.stats.enumerated() {
                let x = pad + CGFloat(i) * (width + gap)
                let tileHeight: CGFloat = content.duet ? 66 : 62
                if draw {
                    stat.fill.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: tileHeight), xRadius: content.duet ? 22 : 14, yRadius: content.duet ? 22 : 14).fill()
                }
                drawLine(stat.value, .systemFont(ofSize: 24, weight: .semibold), stat.ink, x: x + 12, y: y + 8, width: width - 16, draw: draw)
                drawLine(stat.label, .systemFont(ofSize: 12), stat.ink, x: x + 12, y: y + 38, width: width - 16, draw: draw)
            }
            y += (content.duet ? 66 : 62) + 14
        }

        // Chats that need you
        if !content.rows.isEmpty {
            drawLine(content.rowsTitle, .systemFont(ofSize: 12, weight: .semibold), .secondaryLabelColor, x: pad, y: y, width: inner, draw: draw)
            y += 22
            rowHits = []
            for (i, row) in content.rows.enumerated() {
                if draw {
                    row.dot.setFill()
                    NSBezierPath(ovalIn: NSRect(x: pad, y: y + 6, width: 8, height: 8)).fill()
                }
                let nameWidth = drawLine(row.left, .systemFont(ofSize: 13), .labelColor, x: pad + 16, y: y, width: inner - 16, draw: draw)
                // A waiting chat opens its real session, and underlines under the pointer like the latest sessions
                if draw, rowHovered == i, row.link != nil {
                    underline(from: pad + 16, width: nameWidth, y: y + 18, color: .labelColor)
                }
                if let link = row.link { rowHits.append((NSRect(x: pad, y: y, width: inner, height: 20), link)) }
                drawLine(row.right, .systemFont(ofSize: 13), .secondaryLabelColor, x: pad, y: y, width: inner, align: .right, draw: draw)
                y += 22
            }
            y += 8
        }

        for (text, color) in content.lines {
            drawLine(text, .systemFont(ofSize: 13), color, x: pad, y: y, width: inner, draw: draw)
            y += 22
        }

        // The latest sessions, newest first
        if !content.latest.isEmpty {
            drawLine("Latest sessions", .systemFont(ofSize: 12, weight: .semibold), content.duet ? duetPlum : .secondaryLabelColor, x: pad, y: y, width: inner, draw: draw)
            y += 22
            latestHits = []
            for (i, row) in content.latest.enumerated() {
                if draw {
                    row.dot.setFill()
                    NSBezierPath(ovalIn: NSRect(x: pad, y: y + 6, width: 8, height: 8)).fill()
                }
                let nameWidth = drawLine(row.left, .systemFont(ofSize: 13), .labelColor, x: pad + 16, y: y, width: inner - 16, draw: draw)
                if draw, hovered == i, row.link != nil {
                    underline(from: pad + 16, width: nameWidth, y: y + 18, color: .labelColor)
                }
                if row.link != nil { latestHits.append((NSRect(x: pad, y: y, width: inner, height: 20), row.link!)) }
                drawLine(row.right, .systemFont(ofSize: 12), .secondaryLabelColor, x: pad, y: y + 1, width: inner, align: .right, draw: draw)
                y += 22
            }
            y += 8
        }

        // The week, one bar for each day, today dark
        if !content.week.isEmpty {
            drawLine("This week", .systemFont(ofSize: 12, weight: .semibold), .secondaryLabelColor, x: pad, y: y, width: inner, draw: draw)
            y += 22
            let slot = inner / CGFloat(content.week.count)
            let peak = max(1, content.week.map(\.seconds).max() ?? 1)
            let baseY = y + 56
            for (i, bar) in content.week.enumerated() {
                let x = pad + CGFloat(i) * slot
                let height = max(3, CGFloat(bar.seconds) / CGFloat(peak) * 56)
                if draw {
                    (content.duet ? (bar.isToday ? NSColor(hex: 0x3D2C3A) : NSColor(hex: 0xC97A8F)) : (bar.isToday ? NSColor(hex: 0x3B2A20) : NSColor(hex: 0xF4A259))).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x + slot * 0.2, y: baseY - height, width: slot * 0.6, height: height), xRadius: 4, yRadius: 4).fill()
                }
                drawLine(bar.label, .systemFont(ofSize: 11, weight: bar.isToday ? .semibold : .regular),
                         bar.isToday ? .labelColor : .secondaryLabelColor, x: x, y: baseY + 4, width: slot, align: .center, draw: draw)
            }
            y += 56 + 28
        }

        // The top chats by working time
        topHits = []
        if !content.top.isEmpty {
            drawLine("Top chats", .systemFont(ofSize: 12, weight: .semibold), .secondaryLabelColor, x: pad, y: y, width: inner, draw: draw)
            y += 22
            let longest = max(1, content.top.map(\.seconds).max() ?? 1)
            for (i, chat) in content.top.enumerated() {
                let nameWidth = drawLine(chat.name, .systemFont(ofSize: 13), .labelColor, x: pad, y: y, width: inner - 70, draw: draw)
                if draw, topHovered == i, chat.link != nil {
                    underline(from: pad, width: nameWidth, y: y + 18, color: .labelColor)
                }
                if let link = chat.link { topHits.append((NSRect(x: pad, y: y, width: inner, height: 20), link)) }
                drawLine(clockText(chat.seconds), .systemFont(ofSize: 13), .secondaryLabelColor, x: pad, y: y, width: inner, align: .right, draw: draw)
                if draw {
                    let track = NSRect(x: pad, y: y + 22, width: inner, height: 5)
                    NSColor.labelColor.withAlphaComponent(0.1).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
                    (content.duet ? NSColor(hex: 0xC97A8F) : NSColor(hex: 0x1C7ED6)).setFill()
                    NSBezierPath(roundedRect: NSRect(x: pad, y: track.minY, width: inner * CGFloat(chat.seconds) / CGFloat(longest), height: 5), xRadius: 2.5, yRadius: 2.5).fill()
                }
                y += 36
            }
        }

        if let footer = content.footer {
            y += 4
            if content.duet {
                if draw {
                    adaptiveColor(NSColor(hex: 0xF3E9EE), NSColor.white.withAlphaComponent(0.08)).setFill()
                    NSBezierPath(roundedRect: NSRect(x: pad, y: y, width: inner, height: 34), xRadius: 17, yRadius: 17).fill()
                }
                drawLine(footer, .systemFont(ofSize: 13), adaptiveColor(NSColor(hex: 0x6E5566), NSColor(hex: 0xD6C6D0)), x: pad + 14, y: y + 8, width: inner - 28, draw: draw)
                y += 42
            } else {
                drawLine(footer, .systemFont(ofSize: 12), .secondaryLabelColor, x: pad, y: y, width: inner, draw: draw)
                y += 22
            }
        }
        return y + 12
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackHover(self)
    }

    // Underlines the session under the pointer, so it reads as a link
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = latestHits.firstIndex { $0.0.contains(point) }
        let top = topHits.firstIndex { $0.0.contains(point) }
        let waitingRow = rowHits.firstIndex { $0.0.contains(point) }
        if row != hovered || top != topHovered || waitingRow != rowHovered {
            hovered = row
            topHovered = top
            rowHovered = waitingRow
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        topHovered = nil
        rowHovered = nil
        needsDisplay = true
    }

    // The cross closes the card; a session row opens that real chat in Claude; nothing else closes it
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -6, dy: -6).contains(point) { onClose?(); return }
        if pinRect.insetBy(dx: -6, dy: -6).contains(point) { onPin?(); return }
        if let hit = (rowHits + latestHits + topHits).first(where: { $0.0.contains(point) }) { openChat(hit.1) }
    }
}

/// Her chat list, laid out like the mock: a summary, the two limits as cards, and each chat as a box under the group it
/// belongs to, with Allow and Deny under the chat that waits for you
final class ChatListView: NSView {
    /// Wide enough that names, news and buttons fit on one line each, with no sideways scrolling
    static let width: CGFloat = 520
    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    /// The blue for running text and its chip: deep on light glass, bright on dark glass
    static let runningInk = adaptiveColor(NSColor(hex: 0x0A4FA8), NSColor(hex: 0x9CC9FF))
    /// The orange for a chat that is working now, like the reference's "Drafting"
    static let workingInk = adaptiveColor(NSColor(hex: 0xC4500A), NSColor(hex: 0xFFA94D))
    static let runningChip = adaptiveColor(NSColor(hex: 0x0A6CF0).withAlphaComponent(0.14), NSColor(hex: 0x0A6CF0).withAlphaComponent(0.3))
    /// Each chat sits on a faint glass card, with a light edge
    static let glassCard = adaptiveColor(NSColor.white.withAlphaComponent(0.42), NSColor.white.withAlphaComponent(0.09))
    static let glassEdge = adaptiveColor(NSColor.white.withAlphaComponent(0.7), NSColor.white.withAlphaComponent(0.16))
    /// Room on the right for the scrollbar, so it never covers the text
    static let gutter: CGFloat = 22
    static let groups: [(heading: String, color: NSColor)] = [
        ("Running now", runningInk),
        ("", Status.needsInput.color), // no heading: each box says "Needs you" itself
        ("Finished", Status.ready.color),
        ("Resting", .secondaryLabelColor),
    ]

    var chats: [Chat] = []
    var usage: Usage?
    var title = "Mochi"
    var titleColor: NSColor = .labelColor
    var subtitle = ""
    var footer: String?
    /// The running and the last finished session, as lines under the heading
    var activityLines: [(String, NSColor)] = []
    /// The chats whose older news is open, by id
    var expanded = Set<String>()
    /// When each running chat was first seen running, for its timer
    var runningSince: [String: Date] = [:]
    /// The countdowns started from a mochi:// link, by chat
    var countdowns: [String: ChatTimer] = [:]
    var onAnswer: ((Chat, String) -> Void)?
    /// Asked when the list must be sized again, such as after "Show earlier"
    var onRelayout: (() -> Void)?

    enum Hit { case open(String), answer(Chat, String), expand(String), skin(Chat) }
    /// Asked to open the skin editor for a chat
    var onEditSkin: ((Chat) -> Void)?
    /// Where each click goes, in drawing order; the last one under the pointer wins, so a button beats the box around it
    private var hits: [(rect: NSRect, hit: Hit)] = []

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The height the list needs, measured the same way it is drawn
    func fittingHeight() -> CGFloat { render(draw: false) }

    override func draw(_ dirtyRect: NSRect) { render(draw: true) }

    @discardableResult
    private func render(draw: Bool) -> CGFloat {
        hits = []
        let pad: CGFloat = 14
        let inner = Self.width - pad - Self.gutter
        var y: CGFloat = 14

        // Her name, and the open chats and notes beside it
        label(title, .systemFont(ofSize: 15, weight: .medium), titleColor, x: pad, y: y, width: inner * 0.6, draw: draw)
        label(subtitle, .systemFont(ofSize: 13), .secondaryLabelColor, x: pad, y: y + 2, width: inner, align: .right, draw: draw)
        y += 28

        // Which session is running now, and which one finished last
        for (text, color) in activityLines {
            label(text, .systemFont(ofSize: 13, weight: .medium), color, x: pad, y: y, width: inner, draw: draw)
            y += 21
        }
        y += 6

        if chats.isEmpty {
            label("Start a Claude chat and I'll tell you how it goes!", .systemFont(ofSize: 13), .secondaryLabelColor,
                  x: pad, y: y, width: inner, draw: draw)
            y += 22
        }

        // Each group in turn, most urgent first, then the most recent
        let ordered = chats.sorted {
            if $0.isOpen != $1.isOpen { return $0.isOpen }
            if $0.isRecent != $1.isRecent { return $0.isRecent }
            if $0.status.urgency != $1.status.urgency { return $0.status.urgency > $1.status.urgency }
            return $0.updatedAt > $1.updatedAt
        }
        for (index, group) in Self.groups.enumerated() {
            var members = ordered.filter { listGroup($0.status) == index }
            // Finished shows only the latest few, so older ones do not crowd the list
            if index == 2 { members = recentFirst(members, updated: \.updatedAt, limit: finishedLimit) }
            // Running now is always there, at the top, even when nothing is running
            guard !members.isEmpty || groupAlwaysShown(index) else { continue }
            y += 8
            if !group.heading.isEmpty {
                let headingFont = NSFont.systemFont(ofSize: 13, weight: .medium)
                if index == 0 {
                    let width = label(group.heading, headingFont, group.color, x: pad, y: y, width: inner, draw: false)
                    if draw {
                        Self.runningChip.setFill()
                        NSBezierPath(roundedRect: NSRect(x: pad, y: y - 2, width: width + 16, height: 22), xRadius: 8, yRadius: 8).fill()
                    }
                    label(group.heading, headingFont, group.color, x: pad + 8, y: y, width: inner, draw: draw)
                } else {
                    label(group.heading, headingFont, group.color, x: pad, y: y, width: inner, draw: draw)
                }
                y += 24
            }
            if members.isEmpty {
                label("Nothing running right now", .systemFont(ofSize: 13), .secondaryLabelColor, x: pad, y: y, width: inner, draw: draw)
                y += 24
            }
            for chat in members {
                y = box(chat, accent: group.color, top: y, pad: pad, inner: inner, draw: draw)
            }
        }

        // The two limits as cards, with a bar and when each one resets
        if usage != nil { y += 6 }
        if let usage {
            let cardWidth = (inner - 8) / 2
            let limits: [(name: String, percent: Int, resets: String?)] = [
                ("5-hour limit", usage.fiveHour, Usage.until(usage.fiveHourResets)),
                ("Week limit", usage.week, Usage.until(usage.weekResets)),
            ]
            for (i, limit) in limits.enumerated() {
                let x = pad + CGFloat(i) * (cardWidth + 8)
                if draw {
                    Self.glassCard.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: cardWidth, height: 76), xRadius: 16, yRadius: 16).fill()
                }
                label(limit.name, .systemFont(ofSize: 13), .secondaryLabelColor, x: x + 10, y: y + 8, width: cardWidth - 20, draw: draw)
                label("\(limit.percent)%", .systemFont(ofSize: 16, weight: .medium), .labelColor, x: x + 10, y: y + 24, width: cardWidth - 20, draw: draw)
                if draw {
                    let track = NSRect(x: x + 10, y: y + 48, width: cardWidth - 20, height: 4)
                    NSColor.labelColor.withAlphaComponent(0.1).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                    Usage.color(limit.percent).setFill()
                    let filled = track.width * CGFloat(min(100, max(0, limit.percent))) / 100
                    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: filled, height: 4), xRadius: 2, yRadius: 2).fill()
                }
                if let resets = limit.resets {
                    label("Resets in \(resets)", .systemFont(ofSize: 12), .secondaryLabelColor, x: x + 10, y: y + 56, width: cardWidth - 20, draw: draw)
                }
            }
            y += 84
            if let back = usage.backText {
                label("⏳ \(back)", .systemFont(ofSize: 13, weight: .medium), Usage.color(100), x: pad, y: y, width: inner, draw: draw)
                y += 22
            }
        }

        if let footer {
            y += 8
            label(footer, .systemFont(ofSize: 13), .secondaryLabelColor, x: pad, y: y, width: inner, align: .center, draw: draw)
            y += 22
        }
        return y + 10
    }

    /// One chat: its name, state and time, its latest news, and Allow and Deny when it waits for you.
    /// Returns the bottom edge of the box
    /// One chat on a glass card. It is measured first, so the card sits under the text, then drawn
    private func box(_ chat: Chat, accent: NSColor, top: CGFloat, pad: CGFloat, inner: CGFloat, draw: Bool) -> CGFloat {
        if draw {
            let saved = hits
            let bottom = layoutBox(chat, accent: accent, top: top, pad: pad, inner: inner, draw: false)
            hits = saved
            // An inbox row: a hairline under it, starting at the text
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSRect(x: pad + 62, y: bottom - 0.5, width: inner - 62 - 10, height: 0.5).fill()
        }
        return layoutBox(chat, accent: accent, top: top, pad: pad, inner: inner, draw: draw)
    }

    private func layoutBox(_ chat: Chat, accent: NSColor, top: CGFloat, pad: CGFloat, inner: CGFloat, draw: Bool) -> CGFloat {
        let boxIndex = hits.count
        let contentRight = pad + inner - 10
        let textX = pad + 62
        let textWidth = contentRight - textX
        var cy = top + 10

        // Her pixel cat on the left, then the name with the time at the right, like an inbox row
        if draw {
            let look = chatLooks[chat.id] ?? ChatLook()
            drawCatAvatar(chatSkin(id: chat.id, look: look), look: look, in: NSRect(x: pad + 10, y: top + 10, width: 40, height: 40),
                          resting: !chat.isOpen || chat.status == .idle)
        }
        // Clicking her cat opens the skin editor for this chat
        hits.append((rect: NSRect(x: pad + 8, y: top + 8, width: 44, height: 44), hit: .skin(chat)))
        let timeText = ago(chat.updatedAt)
        let timeWidth = label(timeText, .systemFont(ofSize: 13), .secondaryLabelColor, x: contentRight - 120, y: cy, width: 120, align: .right, draw: draw)
        label(chat.title, .systemFont(ofSize: 15, weight: .semibold), .labelColor, x: textX, y: cy, width: max(40, textWidth - timeWidth - 10), draw: draw)
        cy += 22

        // The state under the name: orange while it works, rose when it needs you; an Auto chat says so
        let auto = chat.isOpen && chat.mode == "auto"
        if chat.isOpen, chat.status == .running || chat.status == .needsInput || auto {
            let word = chat.status == .running ? "✦ Working…" : chat.status == .needsInput ? "Needs you" : "Ready"
            let colour = chat.status == .running ? Self.workingInk : chat.status == .needsInput ? Status.needsInput.color : NSColor.secondaryLabelColor
            label((auto ? "Auto · " : "") + word, .systemFont(ofSize: 13, weight: .medium), colour, x: textX, y: cy, width: textWidth, draw: draw)
            cy += 20
        }

        // A countdown you started: the minutes left, and a bar that fills to the end
        if let countdown = countdowns[chat.id] {
            let total = countdown.end.timeIntervalSince(countdown.start)
            let left = countdown.end.timeIntervalSinceNow
            let text = left > 0 ? "Countdown: \(Int(ceil(left / 60))) min left" : "Countdown: time\'s up"
            label(text, .systemFont(ofSize: 12, weight: .medium), Self.runningInk, x: textX, y: cy, width: textWidth, draw: draw)
            cy += 19
            if draw, total > 0 {
                let track = NSRect(x: textX, y: cy + 2, width: textWidth, height: 4)
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                Self.runningInk.setFill()
                let done = min(1, max(0, 1 - left / total))
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(done), height: 4), xRadius: 2, yRadius: 2).fill()
            }
            cy += 12
        }

        // A running chat: how long it has run, and how much of its estimate is used
        if chat.isOpen, chat.status == .running, let started = runningSince[chat.id] {
            let elapsed = Int(Date().timeIntervalSince(started))
            let estimate = taskEstimate(chat.log)
            label(taskTimerText(elapsed: elapsed, estimate: estimate), .systemFont(ofSize: 12, weight: .medium), Self.runningInk,
                  x: textX, y: cy, width: textWidth, draw: draw)
            cy += 19
            if draw {
                let track = NSRect(x: textX, y: cy + 2, width: textWidth, height: 4)
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                Self.runningInk.setFill()
                let filled = track.width * CGFloat(taskProgress(elapsed: elapsed, estimate: estimate))
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: filled, height: 4), xRadius: 2, yRadius: 2).fill()
            }
            cy += 12
        }

        if chat.status == .needsInput, !chat.waiting.isEmpty {
            label(clip(chat.waiting, 90), .systemFont(ofSize: 14), .labelColor, x: textX, y: cy, width: textWidth, draw: draw)
            cy += 22
        }

        // Only the latest news unless the chat is expanded
        let latest = chat.log.sorted { ($0.at ?? 0) > ($1.at ?? 0) }
        let expandedNow = expanded.contains(chat.id)
        if latest.isEmpty {
            label("Nothing yet", .systemFont(ofSize: 13), .secondaryLabelColor, x: textX, y: cy, width: textWidth, draw: draw)
            cy += 20
        }
        for event in latest.prefix(listShownEvents(total: latest.count, expanded: expandedNow)) {
            let took = event.seconds.map { " · \($0)s" } ?? ""
            label("\(icons[event.kind] ?? "•") \(clip(event.summary, 70))\(took) · \(ago(event.at))",
                  .systemFont(ofSize: 13), .secondaryLabelColor, x: textX, y: cy, width: textWidth, draw: draw)
            cy += 20
        }
        if latest.count > 1 {
            let more = expandedNow ? "Show less" : "Show \(latest.count - 1) earlier"
            let width = label(more, .systemFont(ofSize: 13, weight: .medium), Self.runningInk,
                              x: textX, y: cy, width: textWidth, draw: draw)
            hits.append((rect: NSRect(x: textX, y: cy, width: width + 4, height: 20), hit: .expand(chat.id)))
            cy += 20
        }

        // Allow and Deny under the chat that waits for you
        if chat.isOpen, chat.status == .needsInput, !chat.requestId.isEmpty {
            cy += 4
            let deny = NSRect(x: contentRight - 120 - 6 - 84, y: cy, width: 84, height: 24)
            let allow = NSRect(x: contentRight - 120, y: cy, width: 120, height: 24)
            button(deny, "Deny ⌃⌥2", filled: false, draw: draw)
            button(allow, "Allow once ⌃⌥1", filled: true, draw: draw)
            hits.append((rect: deny, hit: .answer(chat, "deny")))
            hits.append((rect: allow, hit: .answer(chat, "allow")))
            cy += 30
        }
        cy += 6

        // The whole box opens the chat, and the rounded border goes around it
        let box = NSRect(x: pad, y: top, width: inner, height: cy - top)
        if let link = chat.link { hits.insert((rect: box, hit: .open(link)), at: boxIndex) }
        return box.maxY
    }

    private func button(_ rect: NSRect, _ title: String, filled: Bool, draw: Bool) {
        drawButton(rect, title, filled: filled, draw: draw)
    }

    private func label(_ text: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat,
                       align: NSTextAlignment = .left, draw: Bool) -> CGFloat {
        drawLine(text, font, color, x: x, y: y, width: width, align: align, draw: draw)
    }

    // Clicks: a button or "Show earlier" first, then the chat's box, and anywhere else closes the list
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hits.last(where: { $0.rect.contains(point) })?.hit else {
            window?.orderOut(nil)
            return
        }
        switch hit {
        case .open(let link):
            openChat(link)
            window?.orderOut(nil)
        case .answer(let chat, let decision):
            onAnswer?(chat, decision)
            window?.orderOut(nil)
        case .expand(let id):
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            onRelayout?()
        case .skin(let chat):
            onEditSkin?(chat)
        }
    }
}

/// The skin editor for one chat: a big preview, then shell, hat, eyewear and extras to pick from
final class SkinEditorView: NSView {
    static let size = NSSize(width: 380, height: 640)
    private let chatID: String
    private let chatTitle: String
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    enum Action { case shell(Int), hat(Int), eyewear(Int), extra(Int), surprise, done }
    private var hits: [(NSRect, Action)] = []
    private var look: ChatLook { chatLooks[chatID] ?? ChatLook() }

    init(chatID: String, title: String) {
        self.chatID = chatID
        self.chatTitle = title
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let accent = NSColor(hex: 0xE8651A)
    private static let tile = adaptiveColor(NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.1))

    override func draw(_ dirtyRect: NSRect) {
        hits = []
        let pad: CGFloat = 22
        let inner = Self.size.width - pad * 2
        drawLine("Chat skin", .systemFont(ofSize: 15, weight: .semibold), .labelColor, x: pad, y: 18, width: inner, align: .center, draw: true)

        // The big preview
        let card = NSRect(x: pad, y: 52, width: inner, height: 150)
        Self.tile.setFill()
        NSBezierPath(roundedRect: card, xRadius: 20, yRadius: 20).fill()
        drawCatAvatar(chatSkin(id: chatID, look: look), look: look, in: NSRect(x: card.midX - 55, y: card.minY + 20, width: 110, height: 110), resting: false)
        drawLine(chatTitle, .systemFont(ofSize: 18, weight: .semibold), .labelColor, x: pad, y: 212, width: inner, align: .center, draw: true)

        // Shell colours: the chat's own first, then the ten colours
        drawLine("Shell", .systemFont(ofSize: 13, weight: .medium), .secondaryLabelColor, x: pad, y: 250, width: inner, draw: true)
        let base = chatSkin(id: chatID, look: ChatLook()).face
        let colours = [base] + shellColours.map { NSColor(hex: $0.hex) }
        let step = inner / CGFloat(colours.count)
        for (i, colour) in colours.enumerated() {
            let rect = NSRect(x: pad + CGFloat(i) * step + (step - 22) / 2, y: 274, width: 22, height: 22)
            colour.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if look.shell == i - 1 { ring(NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3))) }
            hits.append((rect.insetBy(dx: -3, dy: -3), .shell(i - 1)))
        }

        optionRow("Hat", names: hatNames, selected: look.hat, top: 316, pad: pad, inner: inner,
                  variant: { ChatLook(shell: self.look.shell, hat: $0) }, action: { .hat($0) })
        optionRow("Eyewear", names: eyewearNames, selected: look.eyewear, top: 408, pad: pad, inner: inner,
                  variant: { ChatLook(shell: self.look.shell, eyewear: $0) }, action: { .eyewear($0) })
        optionRow("Extras", names: extraNames, selected: look.extra, top: 500, pad: pad, inner: inner,
                  variant: { ChatLook(shell: self.look.shell, extra: $0) }, action: { .extra($0) })

        let surprise = NSRect(x: pad, y: 596, width: inner - 96, height: 32)
        let done = NSRect(x: pad + inner - 88, y: 596, width: 88, height: 32)
        drawButton(surprise, "Surprise me", filled: false, draw: true)
        drawButton(done, "Done", filled: true, draw: true)
        hits.append((surprise, .surprise))
        hits.append((done, .done))
    }

    private func ring(_ path: NSBezierPath) {
        Self.accent.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    /// A row of tiles, each showing her cat with that one piece on
    private func optionRow(_ heading: String, names: [String], selected: Int, top: CGFloat, pad: CGFloat, inner: CGFloat,
                           variant: (Int) -> ChatLook, action: (Int) -> Action) {
        drawLine(heading, .systemFont(ofSize: 13, weight: .medium), .secondaryLabelColor, x: pad, y: top, width: inner, draw: true)
        let gap: CGFloat = 8
        let width = (inner - gap * CGFloat(names.count - 1)) / CGFloat(names.count)
        for i in names.indices {
            let rect = NSRect(x: pad + CGFloat(i) * (width + gap), y: top + 24, width: width, height: 56)
            Self.tile.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            if i == 0 {
                drawLine("None", .systemFont(ofSize: 12), .secondaryLabelColor, x: rect.minX, y: rect.midY - 8, width: rect.width, align: .center, draw: true)
            } else {
                let look = variant(i)
                drawCatAvatar(chatSkin(id: chatID, look: look), look: look, in: NSRect(x: rect.midX - 20, y: rect.midY - 20, width: 40, height: 40), resting: false)
            }
            if i == selected { ring(NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 13, yRadius: 13)) }
            hits.append((rect, action(i)))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let action = hits.last(where: { $0.0.contains(point) })?.1 else { return }
        var now = look
        switch action {
        case .shell(let i): now.shell = i
        case .hat(let i): now.hat = i
        case .eyewear(let i): now.eyewear = i
        case .extra(let i): now.extra = i
        case .surprise: now = randomChatLook(seed: Int.random(in: 0..<1_000_000))
        case .done: onClose?(); return
        }
        chatLooks[chatID] = now == ChatLook() ? nil : now
        saveChatLooks(chatLooks)
        needsDisplay = true
        onChange?()
    }
}

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
    /// Whether the pointer is over the card, so its title shows it can be opened
    var hovering = false
    /// The chat's own colour, as a dot before the title; usage cards have none
    var dot: NSColor?
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
        // The Liquid Glass behind draws the card itself; no coloured bar is drawn on the edge

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let titleX: CGFloat = dot == nil ? 22 : 34
        if let dot { drawDot(dot, at: NSPoint(x: 26, y: 19)) }
        NSAttributedString(string: title, attributes: [
            .font: Self.titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]).draw(in: NSRect(x: titleX, y: 10, width: bounds.width - 30 - titleX, height: 18))
        if hovering {
            let width = min(NSAttributedString(string: title, attributes: [.font: Self.titleFont]).size().width, bounds.width - 30 - titleX)
            underline(from: titleX, width: width, y: 27, color: NSColor.labelColor)
        }
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackHover(self)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    override func mouseMoved(with event: NSEvent) { setHovering(true) }

    private func setHovering(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A chat waiting for your OK, with Allow and Deny under it. It stays until you answer, its time runs out,
/// or the chat moves on. Clicking the title opens the chat to read it first.
/// The question on an approval card, the way Claude's own dialog asks it: "Allow garden to run a command?"
func approvalQuestion(chat: String, waiting: String) -> String {
    let action: String
    if waiting.hasPrefix("Run: ") { action = "run a command" }
    else if waiting.hasPrefix("Edit ") { action = "edit " + waiting.dropFirst(5) }
    else if waiting.hasPrefix("Open ") { action = "open " + waiting.dropFirst(5) }
    else if waiting.hasPrefix("Use ") { action = "use " + waiting.dropFirst(4) }
    else if waiting.isEmpty { action = "go ahead" }
    else { action = waiting.prefix(1).lowercased() + waiting.dropFirst() }
    return "Allow \(chat) to \(action)?"
}

/// A chat waiting for your OK, laid out like Claude's own permission dialog: the question, a line under it,
/// the whole command in a box, then Deny and Allow once with their keys. It stays until you answer, its time
/// runs out, or the chat moves on. Clicking anywhere else on it opens the chat to read it first.
final class ApprovalView: NSView {
    let title: String
    /// The line under the question: the countdown while the card can still be answered
    var subtitle: String
    let body: String
    let accent: NSColor
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    /// "allow" or "deny"
    var onAnswer: ((String) -> Void)?
    /// The chat's own colour, as a dot before the title
    var dot: NSColor?
    override var isFlipped: Bool { true }

    static let size = NSSize(width: 420, height: 214)
    private static let allowColor = NSColor(hex: 0x2F9E44)
    private var denyBox: NSRect { NSRect(x: 22, y: 172, width: 150, height: 28) }
    private var allowBox: NSRect { NSRect(x: bounds.width - 22 - 170, y: 172, width: 170, height: 28) }
    private var closeBox: NSRect { NSRect(x: bounds.width - 28, y: 10, width: 18, height: 18) }

    /// Whether this chat can switch modes; only then does the card list the mode keys
    let offersModes: Bool

    init(title: String, subtitle: String, body: String, accent: NSColor, offersModes: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.accent = accent
        self.offersModes = offersModes
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {

        // The question, in up to two lines, then a line under it
        let wrap = NSMutableParagraphStyle()
        wrap.lineBreakMode = .byWordWrapping
        let titleX: CGFloat = dot == nil ? 22 : 36
        if let dot { drawDot(dot, at: NSPoint(x: 27, y: 21)) }
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: wrap,
        ]).draw(in: NSRect(x: titleX, y: 12, width: bounds.width - 34 - titleX, height: 36))
        NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: wrap,
        ]).draw(in: NSRect(x: 22, y: 50, width: bounds.width - 44, height: 16))

        // The whole command or path, in a box, as Claude's dialog shows it
        let code = NSRect(x: 22, y: 74, width: bounds.width - 44, height: 66)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: code, xRadius: 8, yRadius: 8).fill()
        let charWrap = NSMutableParagraphStyle()
        charWrap.lineBreakMode = .byCharWrapping
        NSAttributedString(string: body, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: charWrap,
        ]).draw(in: code.insetBy(dx: 10, dy: 8))

        // The two mode answers, only in a chat whose plugin can switch modes: otherwise they would do nothing
        if offersModes {
            NSAttributedString(string: "⌃⌥3 allow and accept edits   ·   ⌃⌥4 allow and switch to Auto", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.tertiaryLabelColor,
            ]).draw(at: NSPoint(x: 22, y: 148))
        }

        // Deny on the left, Allow once on the right, each with its key in a small chip
        drawButton(denyBox, "Deny", key: "⌃⌥2", fill: NSColor.labelColor.withAlphaComponent(0.08), outline: nil)
        drawButton(allowBox, "Allow once", key: "⌃⌥1", fill: Self.allowColor.withAlphaComponent(0.12), outline: Self.allowColor)

        NSAttributedString(string: "✕", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
        ]).draw(at: NSPoint(x: closeBox.minX + 4, y: closeBox.minY + 2))
    }

    private func drawButton(_ box: NSRect, _ word: String, key: String, fill: NSColor, outline: NSColor?) {
        let shape = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        fill.setFill()
        shape.fill()
        if let outline {
            outline.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
        let label = NSAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: box.minX + 12, y: box.midY - size.height / 2))
        let chipText = NSAttributedString(string: key, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let chipSize = chipText.size()
        let chip = NSRect(x: box.maxX - chipSize.width - 18, y: box.midY - 9, width: chipSize.width + 10, height: 18)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        chipText.draw(at: NSPoint(x: chip.minX + 5, y: chip.midY - chipSize.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeBox.contains(point) { onClose?() }
        else if allowBox.contains(point) { onAnswer?("allow") }
        else if denyBox.contains(point) { onAnswer?("deny") }
        else { onOpen?() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - This week: what happened each day, kept in ~/.claude/mochi/days.json

/// One chat's turns on one day
struct ChatDay: Codable {
    var title: String
    var turns: Int
    /// Seconds the chat spent working, and waiting for you, on this day, counted while Mochi was open
    var working: Int? = nil
    var waiting: Int? = nil
}

/// What happened on one day: turns finished, approvals you gave, the highest 5-hour usage, and each chat's turns
struct DayRecord: Codable {
    var turns = 0
    var allowed = 0
    var declined = 0
    var peak = 0
    var chats: [String: ChatDay] = [:]

    init() {}

    /// Tolerant of missing keys, so a record written by an older Mochi still reads
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        turns = try saved.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        allowed = try saved.decodeIfPresent(Int.self, forKey: .allowed) ?? 0
        declined = try saved.decodeIfPresent(Int.self, forKey: .declined) ?? 0
        peak = try saved.decodeIfPresent(Int.self, forKey: .peak) ?? 0
        chats = try saved.decodeIfPresent([String: ChatDay].self, forKey: .chats) ?? [:]
    }
}

/// Every recorded day, by its date ("2026-10-16")
typealias DayLog = [String: DayRecord]

let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

/// The day a date falls on, in your time zone
func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

/// The seven dates, Monday to Sunday, of the week that contains `date`
func weekDates(containing date: Date) -> [Date] {
    var calendar = Calendar.current
    calendar.firstWeekday = 2 // weeks start on Monday
    let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
}

/// Counts one finished turn for a chat on a day
func recordTurn(_ log: inout DayLog, day: String, chatID: String, title: String) {
    var record = log[day] ?? DayRecord()
    record.turns += 1
    var chat = record.chats[chatID] ?? ChatDay(title: title, turns: 0)
    chat.title = title
    chat.turns += 1
    record.chats[chatID] = chat
    log[day] = record
}

/// Counts one second of a chat's time on its day: waiting for you, or working
func recordSecond(_ log: inout DayLog, day: String, chatID: String, title: String, waiting: Bool) {
    var record = log[day] ?? DayRecord()
    var chat = record.chats[chatID] ?? ChatDay(title: title, turns: 0)
    chat.title = title
    if waiting { chat.waiting = (chat.waiting ?? 0) + 1 } else { chat.working = (chat.working ?? 0) + 1 }
    record.chats[chatID] = chat
    log[day] = record
}

/// One agent Claude has run: its task, when it started, and when it last did something
struct AgentRun {
    let id: String
    let task: String
    let started: Date
    let lastActivity: Date
}

/// Reads an agent's first line: the task it was given, and when that was. Nil if the line does not read
func agentTask(fromLine line: String) -> (task: String, at: Date)? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = object["message"] as? [String: Any],
          let stamp = object["timestamp"] as? String else { return nil }
    let text: String?
    if let plain = message["content"] as? String {
        text = plain
    } else if let parts = message["content"] as? [[String: Any]] {
        text = parts.compactMap { $0["text"] as? String }.first
    } else {
        text = nil
    }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let text, let at = format.date(from: stamp) else { return nil }
    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    return (clip(firstLine, 60), at)
}

/// Whether an agent counts as running: it did something in the last two minutes
func agentActive(lastActivity: Date, now: Date) -> Bool {
    now.timeIntervalSince(lastActivity) < 120
}

/// Finds the agents Claude has run in the last six hours, newest first, from their own transcripts
func readAgents(now: Date) -> [AgentRun] {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    var runs: [AgentRun] = []
    for project in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        for session in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? [] {
            let folder = session.appendingPathComponent("subagents")
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) < 6 * 3600,
                      let handle = FileHandle(forReadingAtPath: file.path) else { continue }
                let head = String(data: handle.readData(ofLength: 8192), encoding: .utf8) ?? ""
                handle.closeFile()
                guard let firstLine = head.split(separator: "\n", maxSplits: 1).first,
                      let found = agentTask(fromLine: String(firstLine)) else { continue }
                let id = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "agent-", with: "")
                runs.append(AgentRun(id: id, task: found.task, started: found.at, lastActivity: modified))
            }
        }
    }
    return Array(runs.sorted { $0.lastActivity > $1.lastActivity }.prefix(8))
}

/// Whether the wrap-up may show: from 6:00 PM on
func wrapUpDue(now: Date, calendar: Calendar = .current) -> Bool {
    calendar.component(.hour, from: now) >= 18
}

/// The brief due right now: "2026-10-22 AM" at 8:00 AM, "2026-10-22 PM" at 6:00 PM, once per slot. Nil otherwise
func briefSlot(now: Date, lastShown: String?, calendar: Calendar = .current) -> String? {
    // Due from 8 AM, and the wrap-up from 6 PM; each once a day, so a missed minute (asleep, paused) still shows it later
    let hour = calendar.component(.hour, from: now)
    guard hour >= 8 else { return nil }
    let slot = dayKey(now) + (hour >= 18 ? " PM" : " AM")
    return slot == lastShown ? nil : slot
}

/// One big number in a tile: its value, label, and the two colours it is drawn in
struct BriefStat { let value: String; let label: String; let ink: NSColor; let fill: NSColor }
/// A row with a coloured dot: a chat on the left and what it needs on the right
struct BriefRow { let left: String; let right: String; let dot: NSColor; var link: String? = nil }
/// One day's bar in the week chart
struct BriefBar { let label: String; let seconds: Int; let isToday: Bool }
/// A chat in the top list, with its working time today
struct BriefTop { let name: String; let seconds: Int; var link: String? = nil }

/// Everything a brief card shows; the card draws whichever parts are filled
struct BriefContent {
    /// Drawn in the Duet look: cream, a large greeting, soft pastel tiles
    var duet = false
    var title = ""
    var date = ""
    var headline: (big: String, sub: String)?
    var stats: [BriefStat] = []
    var rowsTitle = ""
    var rows: [BriefRow] = []
    /// The seven most recently active sessions, newest first
    var latest: [BriefRow] = []
    var lines: [(String, NSColor)] = []
    var week: [BriefBar] = []
    var top: [BriefTop] = []
    var footer: String?
}

/// The most recently active sessions, newest first, up to the limit
func latestSessions(_ chats: [Chat], limit: Int = 7) -> [Chat] {
    Array(chats.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
}

/// The morning brief ("morning") or the 6 PM wrap-up ("evening"): big numbers first, then what needs you, the week and the top chats
func briefContent(kind: String, chats: [Chat], log: DayLog, now: Date, offer: ResetOffer?, usagePercent: Int?) -> BriefContent {
    // Duet's soft pastels: rose for what needs you, blue for what runs, sage for what is done
    // Light tints in Light mode, deep tints in Dark mode, so they follow the Mac's appearance
    let red = (ink: adaptiveColor(NSColor(hex: 0x7A4658), NSColor(hex: 0xF3C9D6)), fill: adaptiveColor(NSColor(hex: 0xF6D9D5), NSColor(hex: 0x4A2E36)))
    let blue = (ink: adaptiveColor(NSColor(hex: 0x3E5A70), NSColor(hex: 0xBCD6EA)), fill: adaptiveColor(NSColor(hex: 0xDCE8F2), NSColor(hex: 0x2A3A48)))
    let green = (ink: adaptiveColor(NSColor(hex: 0x4F6B3C), NSColor(hex: 0xC9E0B4)), fill: adaptiveColor(NSColor(hex: 0xE4EDD9), NSColor(hex: 0x2F3D28)))
    let plain = (ink: NSColor.labelColor, fill: adaptiveColor(NSColor(hex: 0xFFFFFF).withAlphaComponent(0.6), NSColor.white.withAlphaComponent(0.08)))
    func working(_ record: DayRecord) -> Int { record.chats.values.reduce(0) { $0 + ($1.working ?? 0) } }
    func waited(_ record: DayRecord) -> Int { record.chats.values.reduce(0) { $0 + ($1.waiting ?? 0) } }
    let day = DateFormatter()
    day.dateFormat = "EEE d MMM"
    var content = BriefContent()
    content.duet = true
    content.date = day.string(from: now)
    let waiting = chats.filter { $0.status == .needsInput }
    let running = chats.filter { $0.status == .running }
    if kind == "morning" {
        content.title = "Good morning."
        let yesterday = log[dayKey(now.addingTimeInterval(-86_400))] ?? DayRecord()
        content.stats = [
            BriefStat(value: "\(waiting.count)", label: "Waiting", ink: red.ink, fill: red.fill),
            BriefStat(value: "\(running.count)", label: "Running", ink: blue.ink, fill: blue.fill),
            BriefStat(value: clockText(working(yesterday)), label: "Yesterday", ink: green.ink, fill: green.fill),
        ]
        content.rowsTitle = waiting.isEmpty ? "" : "Needs you first"
        content.rows = waiting.prefix(5).map { BriefRow(left: clip($0.title, 26), right: clip($0.waiting.isEmpty ? "waiting" : $0.waiting, 24), dot: NSColor(hex: 0xC97A8F), link: $0.link) }
        if waiting.isEmpty { content.lines = [("Nothing needs you", Status.ready.color)] }
    } else {
        content.title = "Today's wrap-up."
        let today = log[dayKey(now)] ?? DayRecord()
        content.headline = (clockText(working(today)), "working today · \(clockText(waited(today))) waiting for you")
        content.stats = [
            BriefStat(value: "\(today.turns)", label: "Finished", ink: plain.ink, fill: plain.fill),
            BriefStat(value: "\(today.allowed)", label: "Approvals", ink: plain.ink, fill: plain.fill),
            BriefStat(value: usagePercent.map { "\($0)%" } ?? "–", label: "Usage", ink: plain.ink, fill: plain.fill),
        ]
        let names = DateFormatter()
        names.dateFormat = "EEE"
        content.week = weekDates(containing: now).map { date in
            BriefBar(label: names.string(from: date), seconds: working(log[dayKey(date)] ?? DayRecord()), isToday: dayKey(date) == dayKey(now))
        }
        content.top = today.chats.values.filter { ($0.working ?? 0) > 0 }
            .sorted { ($0.working ?? 0) > ($1.working ?? 0) }.prefix(2)
            .map { BriefTop(name: clip($0.title, 28), seconds: $0.working ?? 0) }
        // Top chats carry their real links: the day record keeps no link, so match each by its title
        for i in content.top.indices {
            content.top[i].link = chats.first { clip($0.title, 28) == content.top[i].name }?.link
        }
    }
    content.latest = latestSessions(chats).map { chat in
        BriefRow(left: clip(chat.title, 26), right: "\(listStateLabel(chat.status)) · \(ago(chat.updatedAt))", dot: chat.status.color, link: chat.link)
    }
    if let offer, let days = resetOfferDaysLeft(useBy: offer.useBy, now: now) {
        content.footer = "Reset offer: \(offer.count) left, \(days) day\(days == 1 ? "" : "s")"
    }
    return content
}

/// A time as words: "3h 40m", "22m", or "under a minute"
func clockText(_ seconds: Int) -> String {
    let minutes = seconds / 60
    if minutes < 1 { return seconds > 0 ? "under a minute" : "0m" }
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

/// Counts one answer you gave: allowed, or declined
func recordAnswer(_ log: inout DayLog, day: String, allowed: Bool) {
    var record = log[day] ?? DayRecord()
    if allowed { record.allowed += 1 } else { record.declined += 1 }
    log[day] = record
}

/// Keeps the highest 5-hour usage seen on a day. Returns true when that changed the record.
@discardableResult
func recordPeak(_ log: inout DayLog, day: String, percent: Int) -> Bool {
    var record = log[day] ?? DayRecord()
    guard percent > record.peak else { return false }
    record.peak = percent
    log[day] = record
    return true
}

/// The totals over some days, with the chats ordered by their turns
struct WeekTotals {
    var turns = 0
    var allowed = 0
    var declined = 0
    var chats: [(id: String, title: String, turns: Int)] = []
}

func weekTotals(_ log: DayLog, days: [String]) -> WeekTotals {
    var totals = WeekTotals()
    var perChat: [String: (title: String, turns: Int)] = [:]
    for key in days {
        guard let record = log[key] else { continue }
        totals.turns += record.turns
        totals.allowed += record.allowed
        totals.declined += record.declined
        for (id, chat) in record.chats {
            perChat[id] = (chat.title, (perChat[id]?.turns ?? 0) + chat.turns)
        }
    }
    totals.chats = perChat.map { (id: $0.key, title: $0.value.title, turns: $0.value.turns) }
        .sorted { $0.turns > $1.turns }
    return totals
}

let daysFile = mochiFolder.appendingPathComponent("days.json")

func readDayLog() -> DayLog {
    guard let data = try? Data(contentsOf: daysFile),
          let log = try? JSONDecoder().decode(DayLog.self, from: data) else { return [:] }
    return log
}

/// Writes the log, keeping the last 120 days so the file stays small
func writeDayLog(_ log: DayLog) {
    let cutoff = dayKey(Date().addingTimeInterval(-120 * 86_400))
    let kept = log.filter { $0.key >= cutoff }
    try? FileManager.default.createDirectory(at: mochiFolder, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(kept) { try? data.write(to: daysFile, options: .atomic) }
}

/// Twelve weeks of days, oldest first, each a Monday to Sunday. The last week is the one containing `now`.
func diaryWeeks(now: Date, weeks: Int = 12) -> [[Date]] {
    guard let monday = weekDates(containing: now).first else { return [] }
    var calendar = Calendar.current
    calendar.firstWeekday = 2
    return (0..<weeks).map { w in
        let start = calendar.date(byAdding: .day, value: -7 * (weeks - 1 - w), to: monday) ?? monday
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

/// What the diary says: days with turns out of the days so far, the busiest day, and the streak up to today
struct DiaryStats {
    var active = 0
    var total = 0
    var busiestKey: String?
    var busiestTurns = 0
    var streak = 0
}

func diaryStats(_ log: DayLog, now: Date) -> DiaryStats {
    var stats = DiaryStats()
    let today = dayKey(now)
    let keys = diaryWeeks(now: now).flatMap { $0 }.map { dayKey($0) }.filter { $0 <= today }
    stats.total = keys.count
    for key in keys {
        let turns = log[key]?.turns ?? 0
        if turns > 0 { stats.active += 1 }
        if turns > stats.busiestTurns {
            stats.busiestTurns = turns
            stats.busiestKey = key
        }
    }
    // The streak counts back from today; today may have no turns yet, so an empty today does not break it
    for key in keys.reversed() {
        if (log[key]?.turns ?? 0) > 0 {
            stats.streak += 1
        } else if key != today {
            break
        }
    }
    return stats
}

/// The week panel, with two tabs. "This week": the week's counts, a bar for each day, that day's peak 5-hour
/// usage, and the busiest chats. "Diary": twelve weeks as squares, the darker the busier.
final class WeekView: NSView {
    static let size = NSSize(width: 380, height: 540)
    private(set) var log: DayLog
    private(set) var usage: Usage?
    private(set) var now: Date
    private let colorFor: (String) -> NSColor
    var tab = 0 // 0 is "This week", 1 is "Diary", 2 is "Time"
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }

    init(log: DayLog, usage: Usage?, now: Date, colorFor: @escaping (String) -> NSColor) {
        self.log = log
        self.usage = usage
        self.now = now
        self.colorFor = colorFor
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Takes the newest day record, usage and time, so the chart moves while the panel is open
    func update(log: DayLog, usage: Usage?, now: Date) {
        self.log = log
        self.usage = usage
        self.now = now
        needsDisplay = true
    }

    private var closeBox: NSRect { NSRect(x: bounds.width - 30, y: 12, width: 16, height: 16) }
    private var tabBoxes: [NSRect] {
        [NSRect(x: 22, y: 10, width: 100, height: 28), NSRect(x: 130, y: 10, width: 100, height: 28), NSRect(x: 238, y: 10, width: 100, height: 28)]
    }
    /// The tabs take the top of the panel; the content is drawn below them
    private static let contentTop: CGFloat = 40
    private static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let turnColor = NSColor(hex: 0xF4A259)
    private static let allowedColor = NSColor(hex: 0x2F9E44)
    private static let ink = NSColor(hex: 0x3B2A20)
    private static let muted = NSColor(hex: 0x7A8192)
    /// Her own colours, from no turns to the busiest: belly cream, then her body orange, then her darker stripes
    private static let peach = ["EEE9E2", "FFE0B5", "F9B57A", "F4A259", "D9822B"]

    private static func peachColor(_ level: Int) -> NSColor {
        NSColor(hex: Int(peach[level], radix: 16) ?? 0)
    }

    private static func level(_ turns: Int) -> Int {
        turns == 0 ? 0 : turns <= 5 ? 1 : turns <= 10 ? 2 : turns <= 15 ? 3 : 4
    }

    override func draw(_ dirtyRect: NSRect) {
        drawTabs()
        drawCross()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 0, y: Self.contentTop)
        if tab == 0 { drawThisWeek() } else if tab == 1 { drawDiary() } else { drawTime() }
        context.restoreGState()
    }

    private func drawTabs() {
        let names = ["This week", "Diary", "Time"]
        for (i, box) in tabBoxes.enumerated() {
            let selected = i == tab
            (selected ? Self.turnColor : NSColor(hex: 0xE9ECF1)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            centered(names[i], in: box, font: .systemFont(ofSize: 13, weight: .semibold),
                     color: selected ? .white : Self.muted)
        }
    }

    private func drawCross() {
        let cross = closeBox.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cross.minX, y: cross.minY)); path.line(to: NSPoint(x: cross.maxX, y: cross.maxY))
        path.move(to: NSPoint(x: cross.maxX, y: cross.minY)); path.line(to: NSPoint(x: cross.minX, y: cross.maxY))
        path.lineWidth = 1.6
        Self.muted.setStroke()
        path.stroke()
    }

    /// Today's time per chat: working and waiting for you, the week's working total, and what it counts
    private func drawTime() {
        let record = log[dayKey(now)] ?? DayRecord()
        let rows = record.chats.map { (id: $0.key, title: $0.value.title, working: $0.value.working ?? 0, waiting: $0.value.waiting ?? 0) }
            .filter { $0.working + $0.waiting > 0 }
            .sorted { $0.working + $0.waiting > $1.working + $1.waiting }
        let working = rows.reduce(0) { $0 + $1.working }
        let waiting = rows.reduce(0) { $0 + $1.waiting }
        let week = weekDates(containing: now).reduce(0) { total, day in
            total + (log[dayKey(day)]?.chats.values.reduce(0) { $0 + ($1.working ?? 0) } ?? 0)
        }
        let pad: CGFloat = 22
        let inner = bounds.width - pad * 2

        // Two tiles: working and waiting for you, today
        let tileWidth = (inner - 10) / 2
        for (i, tile) in [("Working", working), ("Waiting for you", waiting)].enumerated() {
            let x = pad + CGFloat(i) * (tileWidth + 10)
            Self.tileFill.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 8, width: tileWidth, height: 56), xRadius: 12, yRadius: 12).fill()
            drawLine(tile.0, .systemFont(ofSize: 12), Self.timeText, x: x + 10, y: 16, width: tileWidth - 20, draw: true)
            drawLine(clockText(tile.1), .systemFont(ofSize: 18, weight: .medium), Self.ink, x: x + 10, y: 32, width: tileWidth - 20, draw: true)
        }

        // The week day by day: working time on each day, today in orange, its time above each bar
        let days = weekDates(containing: now)
        let dayTotals = days.map { day in log[dayKey(day)]?.chats.values.reduce(0) { $0 + ($1.working ?? 0) } ?? 0 }
        let peak = max(1, dayTotals.max() ?? 1)
        let slot = inner / 7
        let baseY: CGFloat = 190
        let barHeight: CGFloat = 80
        drawLine("This week, day by day", .systemFont(ofSize: 12, weight: .medium), Self.timeText, x: pad, y: 72, width: inner, draw: true)
        for (i, day) in days.enumerated() {
            let x = pad + CGFloat(i) * slot
            let total = dayTotals[i]
            let height = max(2, CGFloat(total) / CGFloat(peak) * barHeight)
            let isToday = dayKey(day) == dayKey(now)
            (isToday ? Self.turnColor : NSColor(hex: 0x0A6CF0).withAlphaComponent(0.7)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + slot * 0.2, y: baseY - height, width: slot * 0.6, height: height), xRadius: 5, yRadius: 5).fill()
            if total > 0 {
                drawLine(clockText(total), .systemFont(ofSize: 11, weight: .medium), Self.ink,
                         x: x, y: baseY - height - 16, width: slot, align: .center, draw: true)
            }
            drawLine(Self.dayNames[i], .systemFont(ofSize: 12, weight: isToday ? .semibold : .regular),
                     isToday ? Self.ink : Self.timeText, x: x, y: baseY + 4, width: slot, align: .center, draw: true)
        }

        // Each chat today: its time, and a bar for its share of the busiest chat
        drawLine("Today by chat", .systemFont(ofSize: 12, weight: .medium), Self.timeText, x: pad, y: 222, width: inner, draw: true)
        var y: CGFloat = 244
        if rows.isEmpty {
            drawLine("Nothing timed today yet. Time counts while a chat is working or waiting for you.",
                     .systemFont(ofSize: 13), Self.timeText, x: pad, y: y, width: inner, draw: true)
        }
        let busiest = max(1, rows.map { $0.working + $0.waiting }.max() ?? 1)
        for row in rows {
            let total = row.working + row.waiting
            drawLine(row.title, .systemFont(ofSize: 13, weight: .medium), Self.ink, x: pad, y: y, width: inner - 90, draw: true)
            drawLine(clockText(total), .systemFont(ofSize: 13), Self.timeText, x: pad, y: y, width: inner, align: .right, draw: true)
            let track = NSRect(x: pad, y: y + 22, width: inner, height: 6)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
            colorFor(row.id).setFill()
            let fill = track.width * CGFloat(total) / CGFloat(busiest)
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fill, height: 6), xRadius: 3, yRadius: 3).fill()
            y += 42
        }

        // The footer: the week's working time, and what is counted
        let footerY = bounds.height - Self.contentTop - 34
        drawLine("This week: \(clockText(week)) working", .systemFont(ofSize: 12), Self.timeText, x: pad, y: footerY, width: inner, draw: true)
        drawLine("Counted while Mochi is open", .systemFont(ofSize: 11), Self.timeText, x: pad, y: footerY + 16, width: inner, draw: true)
    }

    private static let tileFill = NSColor.labelColor.withAlphaComponent(0.06)
    /// Darker grey for the Time tab, so its labels read clearly on the glass
    private static let timeText = NSColor(hex: 0x3F4553)

    private func drawThisWeek() {
        let days = weekDates(containing: now)
        let keys = days.map { dayKey($0) }
        let today = dayKey(now)
        let totals = weekTotals(log, days: keys)

        let range = "\(Self.dayOfMonth(days[0])) to \(Self.dayOfMonth(days[6])) \(Self.monthName(days[6]))"
        draw("Week of \(range)", at: NSPoint(x: 22, y: 6), font: .systemFont(ofSize: 16, weight: .semibold), color: Self.ink)
        draw("\(totals.turns) turns across \(totals.chats.count) chats", at: NSPoint(x: 22, y: 28),
             font: .systemFont(ofSize: 12), color: Self.muted)

        // Three counts, as tiles
        let tiles = [("Turns", totals.turns), ("Allowed", totals.allowed), ("Declined", totals.declined)]
        for (i, tile) in tiles.enumerated() {
            let box = NSRect(x: 22 + CGFloat(i) * 116, y: 56, width: 106, height: 52)
            NSColor(hex: 0xEEF1F6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            centered("\(tile.1)", in: NSRect(x: box.minX, y: box.minY + 7, width: box.width, height: 22),
                     font: .systemFont(ofSize: 18, weight: .semibold), color: Self.ink)
            centered(tile.0, in: NSRect(x: box.minX, y: box.minY + 31, width: box.width, height: 16),
                     font: .systemFont(ofSize: 11), color: Self.muted)
        }

        // Each day: turns and approvals allowed as bars, and that day's peak 5-hour usage as a pill
        draw("Each day", at: NSPoint(x: 22, y: 122), font: .systemFont(ofSize: 13, weight: .semibold), color: Self.ink)
        let base: CGFloat = 278
        let slot = (bounds.width - 44) / 7
        let tallest = CGFloat(max(1, keys.compactMap { log[$0]?.turns }.max() ?? 1))
        let scale = 100 / tallest
        for (i, key) in keys.enumerated() {
            let cx = 22 + slot * (CGFloat(i) + 0.5)
            if key > today {
                centered("·", in: NSRect(x: cx - 10, y: base - 20, width: 20, height: 16), font: .systemFont(ofSize: 14), color: Self.muted)
            } else if let record = log[key] {
                let turnsBar = NSRect(x: cx - 13, y: base - CGFloat(record.turns) * scale, width: 12, height: CGFloat(record.turns) * scale)
                let allowedBar = NSRect(x: cx + 1, y: base - CGFloat(record.allowed) * scale, width: 12, height: CGFloat(record.allowed) * scale)
                Self.turnColor.setFill()
                NSBezierPath(roundedRect: turnsBar, xRadius: 4, yRadius: 4).fill()
                Self.allowedColor.setFill()
                NSBezierPath(roundedRect: allowedBar, xRadius: 4, yRadius: 4).fill()
                if record.turns > 0 {
                    centered("\(record.turns)", in: NSRect(x: cx - 15, y: turnsBar.minY - 15, width: 16, height: 13),
                             font: .systemFont(ofSize: 10, weight: .semibold), color: Self.ink)
                }
                if record.allowed > 0 {
                    centered("\(record.allowed)", in: NSRect(x: cx + 1, y: allowedBar.minY - 15, width: 14, height: 13),
                             font: .systemFont(ofSize: 10, weight: .semibold), color: Self.ink)
                }
                if record.peak > 0 {
                    let pill = NSRect(x: cx - 18, y: base + 22, width: 36, height: 16)
                    Usage.color(record.peak).setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
                    centered("\(record.peak)%", in: pill, font: .systemFont(ofSize: 9, weight: .bold), color: .white)
                }
            }
            centered(Self.dayNames[i], in: NSRect(x: cx - 18, y: base + 4, width: 36, height: 14),
                     font: .systemFont(ofSize: 11, weight: .semibold), color: Self.ink)
        }
        NSColor(hex: 0xDDE2EA).setFill()
        NSRect(x: 22, y: base, width: bounds.width - 44, height: 1).fill()

        // The busiest chats, each in its own colour
        draw("Most active chats", at: NSPoint(x: 22, y: 320), font: .systemFont(ofSize: 13, weight: .semibold), color: Self.ink)
        let rows = Array(totals.chats.prefix(4))
        if rows.isEmpty {
            draw("Nothing recorded this week yet.", at: NSPoint(x: 22, y: 346), font: .systemFont(ofSize: 12), color: Self.muted)
        }
        let most = CGFloat(max(1, rows.first?.turns ?? 1))
        for (i, chat) in rows.enumerated() {
            let y = 344 + CGFloat(i) * 26
            colorFor(chat.id).setFill()
            NSBezierPath(ovalIn: NSRect(x: 22, y: y + 4, width: 10, height: 10)).fill()
            draw(clip(chat.title, 20), at: NSPoint(x: 40, y: y), font: .systemFont(ofSize: 12, weight: .medium), color: Self.ink)
            let track = NSRect(x: 180, y: y + 7, width: 150, height: 6)
            NSColor(hex: 0xE4E8EE).setFill()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
            var fill = track
            fill.size.width = track.width * CGFloat(chat.turns) / most
            colorFor(chat.id).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
            centered("\(chat.turns)", in: NSRect(x: 336, y: y, width: 30, height: 16), font: .systemFont(ofSize: 11), color: Self.muted)
        }

        // Her limit, from the same usage she shows above her
        if let usage {
            let resets = usage.weekResets.map { Self.resetText($0) } ?? "soon"
            draw("Week limit: \(usage.week)% used, resets \(resets)", at: NSPoint(x: 22, y: 452),
                 font: .systemFont(ofSize: 11), color: Self.muted)
        }
    }

    private func drawDiary() {
        let today = dayKey(now)
        let weeks = diaryWeeks(now: now)
        let stats = diaryStats(log, now: now)

        draw("Mochi's diary", at: NSPoint(x: 22, y: 6), font: .systemFont(ofSize: 16, weight: .semibold), color: Self.ink)
        draw("Every square is a day. The darker, the busier.", at: NSPoint(x: 22, y: 28),
             font: .systemFont(ofSize: 12), color: Self.timeText)

        let cell: CGFloat = 21, gap: CGFloat = 5
        let gx: CGFloat = 46, gy: CGFloat = 80
        // Month names, above the first week of each month
        var lastMonth = ""
        for (w, week) in weeks.enumerated() {
            let month = Self.monthName(week[0])
            if Calendar.current.component(.day, from: week[0]) <= 7 && month != lastMonth {
                lastMonth = month
                draw(String(month.prefix(3)), at: NSPoint(x: gx + CGFloat(w) * (cell + gap), y: gy - 18),
                     font: .systemFont(ofSize: 11, weight: .semibold), color: Self.ink)
            }
        }
        // Weekday names, down the left
        for (i, name) in ["Mon", "Wed", "Fri", "Sun"].enumerated() {
            let row = [0, 2, 4, 6][i]
            centered(name, in: NSRect(x: 18, y: gy + CGFloat(row) * (cell + gap), width: 26, height: cell),
                     font: .systemFont(ofSize: 10), color: Self.timeText)
        }
        // The squares
        for (w, week) in weeks.enumerated() {
            for (i, date) in week.enumerated() {
                let key = dayKey(date)
                let rect = NSRect(x: gx + CGFloat(w) * (cell + gap), y: gy + CGFloat(i) * (cell + gap), width: cell, height: cell)
                if key > today {
                    NSColor(hex: 0xC9D0DA).setStroke()
                    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                    outline.lineWidth = 1.5
                    outline.stroke()
                    continue
                }
                let turns = log[key]?.turns ?? 0
                Self.peachColor(Self.level(turns)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                if let busiest = stats.busiestKey, busiest == key {
                    // The busiest day gets her outline and a little face
                    Self.ink.setStroke()
                    let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                    frame.lineWidth = 2
                    frame.stroke()
                    Self.ink.setFill()
                    NSRect(x: rect.minX + 6, y: rect.minY + 7, width: 3, height: 3).fill()
                    NSRect(x: rect.maxX - 9, y: rect.minY + 7, width: 3, height: 3).fill()
                    NSRect(x: rect.minX + 7, y: rect.minY + 13, width: 7, height: 2).fill()
                }
            }
        }

        // Legend, then the stats as tiles
        let legendY = gy + 7 * (cell + gap) + 10
        draw("less", at: NSPoint(x: 22, y: legendY), font: .systemFont(ofSize: 11), color: Self.timeText)
        for i in 0..<5 {
            Self.peachColor(i).setFill()
            NSBezierPath(roundedRect: NSRect(x: 58 + CGFloat(i) * 20, y: legendY + 2, width: 14, height: 14), xRadius: 4, yRadius: 4).fill()
        }
        draw("more", at: NSPoint(x: 164, y: legendY), font: .systemFont(ofSize: 11), color: Self.timeText)

        let busiestText: String
        if let key = stats.busiestKey, let date = dayFormatter.date(from: key) {
            busiestText = "\(Self.shortDay(date))"
        } else {
            busiestText = "none yet"
        }
        let tiles = [("Active days", "\(stats.active) of \(stats.total)"), ("Busiest", busiestText), ("Streak", "\(stats.streak) days")]
        for (i, tile) in tiles.enumerated() {
            let box = NSRect(x: 22 + CGFloat(i) * 116, y: 330, width: 106, height: 52)
            NSColor(hex: 0xEEF1F6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            centered(tile.1, in: NSRect(x: box.minX, y: box.minY + 7, width: box.width, height: 22),
                     font: .systemFont(ofSize: 15, weight: .semibold), color: Self.ink)
            centered(tile.0, in: NSRect(x: box.minX, y: box.minY + 31, width: box.width, height: 16),
                     font: .systemFont(ofSize: 11), color: Self.timeText)
        }
        if let key = stats.busiestKey, let date = dayFormatter.date(from: key) {
            draw("Busiest day: \(Self.shortDay(date)) with \(stats.busiestTurns) turns.", at: NSPoint(x: 22, y: 400),
                 font: .systemFont(ofSize: 12), color: Self.timeText)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeBox.insetBy(dx: -6, dy: -6).contains(point) {
            onClose?()
            return
        }
        for (i, box) in tabBoxes.enumerated() where box.contains(point) {
            tab = i
            needsDisplay = true
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func draw(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }

    private func centered(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private static func dayOfMonth(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: date)
    }

    private static func monthName(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: date)
    }

    private static func shortDay(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: date)
    }

    private static func resetText(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: date)
    }
}

// MARK: - Mochi's little thoughts: a bubble now and then, about her time left or a fact

/// One thought: what it says in bold, what it says under that, and which icon it wears
struct Thought: Equatable {
    enum Kind: Equatable { case timeLeft, lowTime, ready, fact }
    let kind: Kind
    let big: String
    let small: String
}

/// Facts for the thoughts. Check each one before it ships.
let funFacts = [
    "Cats sleep 12 to 16 hours a day. I'm on duty anyway.",
    "Octopuses have three hearts. Plenty of room for a nap.",
    "Honey does not spoil. Edible honey was found in Egyptian tombs.",
]

/// A time as the bubble shows it: "4 h 52 min" or "6 min"
func timeLeftText(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
}

/// The thought to show, or nil when there is nothing to say. `roll` (0 to 1) picks among the thoughts that
/// could be said now, and `factIndex` picks the fact. Her time left shows only while the 5-hour window has
/// a reset still ahead of `now`.
func pickThought(usage: Usage?, readyChats: Int, now: Date, roll: Double, factIndex: Int) -> Thought? {
    var options: [Thought] = []
    if let usage, let resets = usage.fiveHourResets, resets > now {
        let left = timeLeftText(resets.timeIntervalSince(now))
        if usage.fiveHour >= 90 {
            options.append(Thought(kind: .lowTime, big: "\(left) left", small: "at \(usage.fiveHour)% of your 5-hour window. Maybe stretch?"))
        } else {
            options.append(Thought(kind: .timeLeft, big: "\(left) left", small: "in your 5-hour window. Plenty, go on!"))
        }
    }
    if readyChats > 0 {
        options.append(Thought(kind: .ready, big: "\(readyChats) chat\(readyChats == 1 ? "" : "s") ready for you",
                               small: "I'll keep the rest warm. No rush."))
    }
    if !funFacts.isEmpty {
        let index = min(max(factIndex, 0), funFacts.count - 1)
        options.append(Thought(kind: .fact, big: "Did you know?", small: funFacts[index]))
    }
    guard !options.isEmpty else { return nil }
    return options[min(options.count - 1, Int(max(0, min(roll, 0.999)) * Double(options.count)))]
}

/// The bubble above her: a white thought with its icon, two lines of text, and three dots leading to her
final class ThoughtView: NSView {
    /// As small as the notification cards: the same width, and a short bubble
    static let size = NSSize(width: 300, height: 64)
    let thought: Thought
    var onDismiss: (() -> Void)?
    override var isFlipped: Bool { true }

    init(thought: Thought) {
        self.thought = thought
        super.init(frame: NSRect(origin: .zero, size: Self.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var accent: NSColor {
        switch thought.kind {
        case .timeLeft: return NSColor(hex: 0x2F9E44)
        case .lowTime: return NSColor(hex: 0xE03131)
        case .ready: return NSColor(hex: 0x1C7ED6)
        case .fact: return NSColor(hex: 0xF4A259)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 2, y: 2, width: bounds.width - 4, height: 46)
        let shape = NSBezierPath(roundedRect: body, xRadius: 16, yRadius: 16)
        NSColor.white.setFill()
        shape.fill()
        NSColor(hex: 0xE6D5B8).setStroke()
        shape.lineWidth = 1.5
        shape.stroke()

        // The icon, in a small circle of its own colour
        accent.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: body.midY - 16, width: 32, height: 32)).fill()
        drawIcon(center: NSPoint(x: 28, y: body.midY))

        let big = NSAttributedString(string: thought.big, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor(hex: 0x3B2A20),
        ])
        big.draw(at: NSPoint(x: 54, y: 9))
        let small = NSMutableParagraphStyle()
        small.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: thought.small, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(hex: 0x8A7866), .paragraphStyle: small,
        ]).draw(in: NSRect(x: 54, y: 26, width: body.width - 66, height: 16))

        // Two small dots leading down to her
        NSColor.white.setFill()
        NSColor(hex: 0xE6D5B8).setStroke()
        for (radius, y, dx) in [(3.5, 53.0, 0.0), (2.2, 60.0, -6.0)] {
            let dot = NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.4 + dx - radius, y: y - radius, width: radius * 2, height: radius * 2))
            dot.lineWidth = 1.5
            dot.fill()
            dot.stroke()
        }
    }

    private func drawIcon(center c: NSPoint) {
        accent.setFill()
        accent.setStroke()
        switch thought.kind {
        case .timeLeft:
            let clock = NSBezierPath(ovalIn: NSRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20))
            clock.lineWidth = 2.5
            clock.stroke()
            let hands = NSBezierPath()
            hands.move(to: c); hands.line(to: NSPoint(x: c.x, y: c.y - 6))
            hands.move(to: c); hands.line(to: NSPoint(x: c.x + 5, y: c.y + 2))
            hands.lineWidth = 2.5
            hands.stroke()
        case .lowTime:
            let flame = NSBezierPath()
            flame.move(to: NSPoint(x: c.x, y: c.y - 11))
            flame.line(to: NSPoint(x: c.x + 9, y: c.y + 2)); flame.line(to: NSPoint(x: c.x + 4, y: c.y + 10))
            flame.line(to: NSPoint(x: c.x - 4, y: c.y + 10)); flame.line(to: NSPoint(x: c.x - 9, y: c.y + 2))
            flame.close()
            flame.fill()
        case .ready:
            NSBezierPath(roundedRect: NSRect(x: c.x - 11, y: c.y - 9, width: 22, height: 16), xRadius: 6, yRadius: 6).fill()
        case .fact:
            let star = NSBezierPath()
            for k in 0..<10 {
                let r: CGFloat = k % 2 == 0 ? 11 : 5
                let a = -CGFloat.pi / 2 + CGFloat(k) * CGFloat.pi / 5
                let point = NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                if k == 0 { star.move(to: point) } else { star.line(to: point) }
            }
            star.close()
            star.fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onDismiss?() }
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

        // After a reset, /usage says "Current session: 0% used" with no reset time, so the time is optional
        guard let fiveRead = usageReading(in: output, line: "Current session"),
              let weekRead = usageReading(in: output, line: "Current week[^:]*")
        else { done(false); return }
        let fiveNow = (fiveRead.percent, fiveRead.resets.flatMap(parseResetDate))
        let weekNow = (weekRead.percent, weekRead.resets.flatMap(parseResetDate))

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

/// Keys that work from any app, even when Mochi is not in front: Control-Option-N for a quick note,
/// Control-Option-M to talk. They are registered with the system, so they need no extra permission.
enum Shortcuts {
    static var actions: [UInt32: () -> Void] = [:]
    /// What macOS said for each shortcut when Mochi registered it, by shortcut id
    static var results: [String: Int] = [:]
    private static var installed = false

    static func add(_ id: UInt32, key: Int, modifiers: Int = optionKey, _ action: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            _ = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                DispatchQueue.main.async { mochiLog("shortcut \(pressed.id) pressed"); Shortcuts.actions[pressed.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        actions[id] = action
        var ref: EventHotKeyRef?
        let hotKey = EventHotKeyID(signature: 0x4D4F4348, id: id) // 'MOCH'
        // 0 means macOS accepted the shortcut; anything else is an error code, written to shortcuts.json
        results["\(id)"] = Int(RegisterEventHotKey(UInt32(key), UInt32(modifiers), hotKey, GetApplicationEventTarget(), 0, &ref))
    }
}

final class Mochi: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let window = floatingPanel(size: NSSize(width: 130, height: 162))
    let view = MochiView()
    let bubble = floatingPanel(size: NSSize(width: 260, height: 40))
    let bubbleView = BubbleView()
    /// Her chat list, shown in the bubble above her
    let chatList = ChatListView()
    /// The countdowns started from a mochi:// link, by chat
    var countdowns: [String: ChatTimer] = [:]
    /// The chats running at the last check, to tell when one stops
    var previouslyRunning = Set<String>()
    /// When a chat last finished, for the green ring
    var lastFinishedAt: Date?
    /// Every agent read recently, running or not
    var allAgents: [AgentRun] = []
    /// The morning brief and the 6 PM wrap-up, under her until you close them
    lazy var briefPanel = floatingPanel(size: NSSize(width: BriefView.width, height: 120))
    /// The card now open, and which brief it shows ("morning" or "evening") so it can keep itself current
    var currentBrief: BriefView?
    var briefLiveKind: String?
    /// When each running chat was first seen running, for its timer
    var runningSince: [String: Date] = [:]
    /// Her usage status box, shown in the bubble above her
    let usagePanel = UsagePanelView()
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

    /// The Allow and Deny cards by the tool call they answer, and the calls already answered, so none comes back
    /// Each day's turns, approvals and peak usage, for "This week"; saved a few seconds after a change
    var dayLog: DayLog = readDayLog()
    var dayLogDirty = false
    var dayLogSavedAt = Date.distantPast
    /// The open "This week" panel, if any
    var weekPanel: NSPanel?
    var skinPanel: NSPanel?
    weak var weekView: WeekView?
    /// Her thought bubble, when one is up, and when she may next think out loud
    var thoughtPanel: NSPanel?
    var nextThoughtAt = Date().addingTimeInterval(5 * 60)
    var approvals: [String: NSPanel] = [:]
    /// The card view inside each approval panel, so its countdown can be updated
    var approvalViews: [String: ApprovalView] = [:]
    /// A pretend chat waiting for your OK, from "Test the approval keys" in her menu. Nothing real is approved.
    var testChat: Chat?
    var answered = Set<String>()
    /// How long after a chat asks she may still answer for it. The plugin waits 8 seconds in all, so
    /// this ends a second sooner, and her buttons go before the plugin stops waiting for them
    static let answerWindow: Double = 7_000
    /// Whether she shows Allow and Deny for a chat that waits for your OK; on by default, switched off in her menu
    var approveHere: Bool {
        get { UserDefaults.standard.object(forKey: "approveHere") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "approveHere") }
    }

    /// The notification cards beside Mochi, newest first
    var cards: [NSPanel] = []
    static let maxCards = 5

    /// On by default: she only pops up for a chat that needs your OK. Finished work, usage warnings and her
    /// thoughts still go to her list and her pill, not to a card, sound or Mac notification.
    var notificationsHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationsHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsHidden") }
    }
    var onlyApprovals: Bool {
        get { UserDefaults.standard.object(forKey: "onlyApprovals") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "onlyApprovals") }
    }
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

/// The reset offer you entered, kept on this Mac; nil when there is none
var resetOffer: ResetOffer? {
    get {
        let defaults = UserDefaults.standard
        guard let useBy = defaults.object(forKey: "resetOfferUseBy") as? Double else { return nil }
        return ResetOffer(count: defaults.integer(forKey: "resetOfferCount"), useBy: Date(timeIntervalSince1970: useBy))
    }
    set {
        let defaults = UserDefaults.standard
        if let newValue {
            defaults.set(newValue.useBy.timeIntervalSince1970, forKey: "resetOfferUseBy")
            defaults.set(newValue.count, forKey: "resetOfferCount")
        } else {
            defaults.removeObject(forKey: "resetOfferUseBy")
            defaults.removeObject(forKey: "resetOfferCount")
        }
    }
}

/// When she stops being quiet, in seconds since 1970. 0 when she is not quiet.
var quietUntil: Double {
    get { UserDefaults.standard.double(forKey: "quietUntil") }
    set { UserDefaults.standard.set(newValue, forKey: "quietUntil") }
}

/// Mochi's sounds play at a fifth of the Mac's volume, and not at all while she is quiet
func playAtTwoThirds(_ sound: NSSound?) {
    guard !quietAt(until: quietUntil, now: Date().timeIntervalSince1970) else { return }
    sound?.volume = 1.0 / 5.0
    sound?.play()
}

/// Plays the "a chat needs you" sound, whatever the notification settings
    func playNeedsSound() {
        guard needsSound != "None" else { return }
        playAtTwoThirds(NSSound(named: NSSound.Name(needsSound)))
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

    /// A mochi:// link from Terminal or another app: "open \"mochi://countdown?chat=Redo%20the%20search&minutes=47\""
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleMochiLink(url) }
    }

    func handleMochiLink(_ url: URL) {
        guard let link = parseMochiLink(url) else {
            mochiLog("link: not understood \(url.absoluteString)")
            return
        }
        switch link {
        case .countdown(let name, let minutes):
            guard let chat = chatNamed(name, in: chats) else {
                showCard(title: "No chat to count down", body: "No open chat called \(name)", color: Status.blocked.color, link: nil)
                return
            }
            let now = Date()
            countdowns[chat.id] = ChatTimer(title: chat.title, start: now, end: now.addingTimeInterval(Double(minutes) * 60))
            mochiLog("countdown: \(minutes) min for \(chat.title)")
            showCard(title: "Countdown: \(chat.title)", body: "\(minutes) min. I\'ll tell you when it\'s up.", color: Status.running.color, link: chat.link, dot: chatColor(chat.id))
        case .brief(let kind):
            showBrief(kind, now: Date())
        case .stop(let name):
            let key = name?.lowercased() ?? ""
            guard let entry = countdowns.first(where: { key.isEmpty || $0.value.title.lowercased().contains(key) }) else {
                showCard(title: "No countdown to stop", body: "Nothing is counting down right now.", color: Status.idle.color, link: nil)
                return
            }
            countdowns[entry.key] = nil
            mochiLog("countdown: stopped for \(entry.value.title)")
            showCard(title: "Countdown stopped: \(entry.value.title)", body: "Mochi won\'t tell you when it\'s up.", color: Status.idle.color, link: nil)
        }
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
        chatList.onAnswer = { [weak self] chat, decision in self?.answerApproval(chat, decision) }
        chatList.onRelayout = { [weak self] in self?.showList() }
        chatList.onEditSkin = { [weak self] chat in self?.showSkinEditor(chat) }
        usagePanel.onRefresh = { [weak self] in self?.showUsageDetails() }
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
        view.onAgentsClick = { [weak self] in self?.showAgents() }
        view.onUsageClick = { [weak self] in
            mochiLog("usage pill clicked")
            self?.showUsageDetails()
        }
        view.onQuickNote = { [weak self] in self?.toggleNote() }
        view.onTalk = { [weak self] in self?.toggleTalk() }
        view.onScroll = { [weak self] in self?.toggleWeek() }
        view.onMenu = { [weak self] event in self?.showMenu(event) }
        Shortcuts.add(1, key: kVK_F5, modifiers: 0) { [weak self] in self?.toggleNote() }
        Shortcuts.add(2, key: kVK_F6, modifiers: 0) { [weak self] in self?.toggleTalk() }
        Shortcuts.add(3, key: kVK_ANSI_J) { [weak self] in self?.jumpToWaiting() }
        Shortcuts.add(4, key: kVK_F7, modifiers: 0) { [weak self] in self?.answerWaiting("allow") }
        Shortcuts.add(5, key: kVK_F8, modifiers: 0) { [weak self] in self?.answerWaiting("deny") }
        Shortcuts.add(6, key: kVK_F9, modifiers: 0) { [weak self] in self?.answerWaiting("acceptEdits") }
        Shortcuts.add(7, key: kVK_F10, modifiers: 0) { [weak self] in self?.answerWaiting("auto") }
        // The same four answers on Control-Option 1 to 4, which work without holding Fn (the F-keys above
        // are media keys on a Mac unless Fn is held)
        Shortcuts.add(8, key: kVK_ANSI_1, modifiers: controlKey | optionKey) { [weak self] in self?.answerWaiting("allow") }
        Shortcuts.add(9, key: kVK_ANSI_2, modifiers: controlKey | optionKey) { [weak self] in self?.answerWaiting("deny") }
        Shortcuts.add(10, key: kVK_ANSI_3, modifiers: controlKey | optionKey) { [weak self] in self?.answerWaiting("acceptEdits") }
        Shortcuts.add(11, key: kVK_ANSI_4, modifiers: controlKey | optionKey) { [weak self] in self?.answerWaiting("auto") }
        // Which shortcuts macOS accepted, in shortcuts.json: 0 is accepted, anything else is an error code
        let names = ["1": "quick note F5", "2": "talk F6", "3": "jump Option-J", "4": "allow F7",
                     "5": "deny F8", "6": "accept edits F9", "7": "auto F10", "8": "allow Control-Option-1",
                     "9": "deny Control-Option-2", "10": "accept edits Control-Option-3", "11": "auto Control-Option-4"]
        writeJSON(Dictionary(uniqueKeysWithValues: Shortcuts.results.map { (names[$0.key] ?? $0.key, $0.value as Any) }),
                  to: mochiFolder.appendingPathComponent("shortcuts.json"))
        view.onBadgeClick = { [weak self] in self?.jumpToWaiting() }
        // Old reports pile up otherwise, and she reads every one each second
        DispatchQueue.global(qos: .utility).async { pruneOldSessions() }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { pruneOldSessions() }
        }
        NotificationCenter.default.addObserver(forName: .mochiMoved, object: nil, queue: .main) { [weak self] _ in
            self?.placeBubble()
            self?.placeCards()
            if self?.briefPanel.isVisible == true { self?.placeBrief() }
            if self?.note.isVisible == true { self?.placeNote() }
        }

        Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.view.tick += 1
            // The buttons show while the pointer is near her, whatever the hover events did
            self.view.nearby = buttonsShowFor(pointer: NSEvent.mouseLocation, frame: self.window.frame)
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
        if let testChat { chats.append(testChat) }
        checkUsage()
        view.status = chats.filter { $0.isOpen && $0.isRecent }.max(by: { $0.status.urgency < $1.status.urgency })?.status ?? .idle
        // When each chat was first seen running, for its timer; forgotten once it stops
        let running = Set(chats.filter { $0.status == .running }.map(\.id))
        for id in running where runningSince[id] == nil { runningSince[id] = Date() }
        runningSince = runningSince.filter { running.contains($0.key) }
        // Mochi's circle: the first running chat that still has time left on its estimate
        view.taskMinutesLeft = chats.lazy.compactMap { chat -> Int? in
            guard chat.status == .running, let started = self.runningSince[chat.id] else { return nil }
            return taskCircleMinutes(elapsed: Int(Date().timeIntervalSince(started)), estimate: taskEstimate(chat.log))
        }.first
        // The ring round her badge: how far the first running chat with an estimate has got, and green when one finishes
        var fraction: Double?
        for chat in chats where chat.status == .running {
            guard let started = runningSince[chat.id], let estimate = taskEstimate(chat.log) else { continue }
            fraction = taskProgress(elapsed: Int(Date().timeIntervalSince(started)), estimate: estimate)
            break
        }
        view.ringFraction = fraction
        let stopped = previouslyRunning.subtracting(running)
        if chats.contains(where: { stopped.contains($0.id) && $0.status == .ready }) { lastFinishedAt = Date() }
        previouslyRunning = running
        view.finishedAt = lastFinishedAt
        // The agents running now, read every few seconds from their own transcripts
        if Int(Date().timeIntervalSince1970) % 5 == 0 {
            allAgents = readAgents(now: Date())
        }
        view.activeAgents = allAgents.filter { agentActive(lastActivity: $0.lastActivity, now: Date()) }
        refreshBrief()
        refreshBriefVisibility()
        refreshWeek()
        // The morning brief at 8:00 AM and the wrap-up at 6:00 PM, once each
        if let slot = briefSlot(now: Date(), lastShown: UserDefaults.standard.string(forKey: "lastBriefSlot")) {
            UserDefaults.standard.set(slot, forKey: "lastBriefSlot")
            showBrief(slot.hasSuffix("AM") ? "morning" : "evening", now: Date())
        }
        // A countdown that is up: say so once, then forget it. While one runs, its minutes take the circle
        for (id, countdown) in countdowns where countdown.end <= Date() {
            countdowns[id] = nil
            let minutes = Int(countdown.end.timeIntervalSince(countdown.start) / 60)
            showCard(title: "Time\'s up: \(countdown.title)", body: "Your \(minutes) min countdown has finished.", color: Status.ready.color, link: nil, dot: chatColor(id))
            playNeedsSound()
        }
        if let next = countdowns.values.min(by: { $0.end < $1.end }) {
            view.taskMinutesLeft = max(1, Int(ceil(next.end.timeIntervalSinceNow / 60)))
        }
        // Sparkles only while a live chat is in Auto
        view.autoMode = chats.contains(where: approvingOnItsOwn)

        var fresh: [(Event, Chat)] = []
        for chat in chats {
            for event in chat.log {
                let key = "\(chat.id)|\(event.at ?? 0)|\(event.text)"
                if seen.insert(key).inserted, !firstLook { fresh.append((event, chat)) }
            }
            // A chat that just started waiting for you
            if chat.status == .needsInput, needsYou(waiting: chat.waiting), needed.insert(chat.id).inserted, !firstLook {
                let why = chat.waiting.isEmpty ? "Waiting for your OK" : chat.waiting
                // With Allow and Deny to answer on, their card carries the question instead
                if !approveHere || chat.requestId.isEmpty {
                    showCard(title: "⏰ \(chat.title) needs you", body: why, color: Status.needsInput.color,
                             link: chat.link, dot: chatColor(chat.id))
                }
                notify(title: "⏰ \(chat.title) needs you", body: why, link: chat.link, silent: true)
                playNeedsSound()
            }
            if chat.status != .needsInput { needed.remove(chat.id) }
        }
        firstLook = false

        refreshChatList()
        // Each second a chat is working or waiting for you counts toward today, while Mochi is open
        for chat in chats where chat.status == .running || chat.status == .needsInput {
            recordSecond(&dayLog, day: dayKey(Date()), chatID: chat.id, title: chat.title, waiting: chat.status == .needsInput)
            dayLogDirty = true
        }
        // Each new finished turn counts toward its day, for "This week"
        for (event, chat) in fresh where event.kind == "turn" {
            let when = Date(timeIntervalSince1970: (event.at ?? Date().timeIntervalSince1970 * 1000) / 1000)
            recordTurn(&dayLog, day: dayKey(when), chatID: chat.id, title: chat.title)
            dayLogDirty = true
        }
        if dayLogDirty, Date().timeIntervalSince(dayLogSavedAt) > 5 {
            writeDayLog(dayLog)
            dayLogDirty = false
            dayLogSavedAt = Date()
        }

        // While she is quiet, or only approvals are wanted, finished work gets no card, sound or Mac notification;
        // the count still goes up
        let quiet = quietAt(until: quietUntil, now: Date().timeIntervalSince1970)
        let finishedShows = !quiet && noticeAllowed(.finished, onlyApprovals: onlyApprovals)
        if !fresh.isEmpty {
            view.unread += fresh.count
            // A card beside Mochi for every new thing, oldest first so the newest lands on top
            for (event, chat) in fresh.sorted(by: { ($0.0.at ?? 0) < ($1.0.at ?? 0) }) where finishedShows {
                let color = event.text == "Stopped" ? Status.blocked.color : chat.status.color
                showCard(title: event.headline(chat.title), body: event.summary, color: color, link: chat.link,
                         dot: chatColor(chat.id))
            }
            if finishedShows { playAtTwoThirds(NSSound(named: "Pop")) }
        }
        // One Mac notification per new event, oldest first
        for (event, chat) in fresh.sorted(by: { ($0.0.at ?? 0) < ($1.0.at ?? 0) }) where finishedShows {
            notify(title: event.headline(chat.title), body: event.summary, link: chat.link)
        }
        syncApprovals()
        if view.status == .needsInput { hideThought() }
        maybeThink()
    }

    /// Opens the chat that has waited longest for your OK; says so when none is waiting
    func jumpToWaiting() {
        guard let chat = oldestWaiting(chats) else {
            say("No chat needs you right now", color: Status.ready.color)
            return
        }
        if chat.link == nil {
            say("⏰ \(chat.title) needs you in its terminal", color: Status.needsInput.color)
        } else {
            openChat(chat.link)
        }
    }

    /// A card when usage passes 80% or reaches 100% of the 5-hour window or the week
    func checkUsage() {
        guard let now = Usage.read() else { return }
        let isFirst = usage == nil
        usage = now
        view.usage = now
        if recordPeak(&dayLog, day: dayKey(Date()), percent: now.fiveHour) { dayLogDirty = true }
        func level(_ percent: Int) -> Int { percent >= 100 ? 100 : percent >= 80 ? 80 : 0 }
        let five = level(now.fiveHour), week = level(now.week)
        if isFirst { warnedFiveHour = five; warnedWeek = week; wasBlocked = now.blocked != nil; return } // no warning for what was already so at launch
        let usageShows = noticeAllowed(.usage, onlyApprovals: onlyApprovals)
        // You ran out: say when you can continue
        if usageShows, let back = now.backText, !wasBlocked {
            showCard(title: "⏳ \(now.blocked?.what ?? "Limit") reached", body: back,
                     color: Usage.color(100), link: nil)
            warnedFiveHour = max(warnedFiveHour, five); warnedWeek = max(warnedWeek, week)
        } else if usageShows, five > warnedFiveHour, five < 100 {
            showCard(title: "⚠️ 5-hour usage at \(now.fiveHour)%", body: "Week: \(now.week)% used",
                     color: Usage.color(now.fiveHour), link: nil)
        } else if usageShows, week > warnedWeek, week < 100 {
            showCard(title: "⚠️ Weekly usage at \(now.week)%",
                     body: "5-hour window: \(now.fiveHour)% used", color: Usage.color(now.week), link: nil)
        }
        // The limit lifted: you can continue
        if usageShows, wasBlocked, now.blocked == nil {
            showCard(title: "✅ Claude is back", body: "Your usage reset. You can continue!",
                     color: Status.ready.color, link: nil)
            playAtTwoThirds(NSSound(named: "Glass"))
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
        usagePanel.usage = usage
        usagePanel.resetOffer = resetOffer
        usagePanel.checking = updating
        usagePanel.footnote = updating ? "Checking now…" : fresh ? "Checked \(when)" : "Last read \(when)"
        showUsagePanel(accent: Usage.color(worst))
        mochiLog("usage box shown: \(usageState(worst: worst)), \(updating ? "checking" : fresh ? "fresh" : "last read")")
        // It closes on its own fifteen seconds after a reading, long enough to read it, and stays open while Claude is being asked
        hideBubble?.invalidate()
        guard !updating else { return }
        hideBubble = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.bubble.orderOut(nil)
            self?.placeCards()
        }
    }

    /// A notification card beside Mochi; it fades out on its own after a while
    func showCard(title: String, body: String, color: NSColor, link: String?, seconds: Double = 5, dot: NSColor? = nil) {
        guard cardMayShow(hidden: notificationsHidden) else { return }
        mochiLog("card: \(title) | \(body)")
        let panel = floatingPanel(size: CardView.size)
        panel.acceptsMouseMovedEvents = true // so the title underlines under the pointer
        panel.hasShadow = false // the glass draws its own soft edge
        let card = CardView(title: title, body: body, accent: color)
        card.dot = dot
        let glass = glassBackground(for: card, tint: color)
        card.onOpen = { [weak self, weak panel] in
            openChat(link)
            if let panel { self?.dismiss(panel) }
        }
        card.onClose = { [weak self, weak panel] in if let panel { self?.dismiss(panel) } }
        panel.contentView = glass
        panel.alphaValue = 0

        cards.insert(panel, at: 0)
        // The cap never pushes out an Allow and Deny card: a chat waiting for you stays put
        while cards.count > Self.maxCards, let oldest = cards.last(where: { panel in !approvals.values.contains(panel) }) {
            dismiss(oldest)
        }
        placeCards()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }

        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self, weak panel] _ in
            if let panel { self?.dismiss(panel) }
        }
    }

    /// macOS Liquid Glass behind a card, the same glass the system's own notifications use,
    /// lightly tinted by the card's colour
    func glassBackground(for card: NSView, tint: NSColor) -> NSView {
        let glass = makeGlass(size: card.frame.size, content: card, radius: 18)
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

    // MARK: - Allow and Deny from Mochi

    /// Each chat waiting for your OK gets an Allow and Deny card while its tool call can still be answered.
    /// A card goes once you answer, the chat moves on, or the time runs out. Also tells the plugin she is here.
    func syncApprovals() {
        let now = Date().timeIntervalSince1970 * 1000
        let asking = approveHere ? chats.filter {
            $0.status == .needsInput && !$0.requestId.isEmpty && now - $0.askedAt < Self.answerWindow
                && needsYou(waiting: $0.waiting) && !answered.contains($0.requestId)
        } : []
        answered = answered.filter { id in chats.contains { $0.requestId == id } }
        let ids = Set(asking.map { $0.requestId })
        for id in Array(approvals.keys) where !ids.contains(id) { closeApproval(id) }
        for chat in asking where approvals[chat.requestId] == nil { showApproval(chat) }
        // The countdown: how long is left to answer each card
        for chat in asking {
            let left = answerSecondsLeft(askedAt: chat.askedAt, now: now, window: Self.answerWindow)
            approvalViews[chat.requestId]?.subtitle = left == 1 ? "Answer in 1 second, or Claude asks you itself."
                : "Answer in \(left) seconds, or Claude asks you itself."
            approvalViews[chat.requestId]?.needsDisplay = true
        }

        // The plugin waits for her answer only while she is here and showing the request
        if approveHere {
            // "auto" says whether she is showing the Auto sparkles, so a test can check what she shows
            writeJSON(["at": now, "pending": asking.map { $0.requestId }, "auto": view.autoMode],
                      to: mochiFolder.appendingPathComponent("presence.json"))
        }
    }

    func showApproval(_ chat: Chat) {
        mochiLog("card shown for \(chat.title) (\(chat.requestId)): \(!chat.detail.isEmpty ? chat.detail : chat.waiting)")
        let id = chat.requestId
        let panel = floatingPanel(size: ApprovalView.size)
        panel.acceptsMouseMovedEvents = true
        panel.hasShadow = false // the glass draws its own soft edge
        // The whole command or path when Claude sent it, else the short line
        let why = !chat.detail.isEmpty ? chat.detail : chat.waiting.isEmpty ? "Waiting for your OK" : chat.waiting
        let card = ApprovalView(title: approvalQuestion(chat: chat.title, waiting: chat.waiting),
                                subtitle: "Answer in 7 seconds, or Claude asks you itself.",
                                body: why, accent: Status.needsInput.color, offersModes: chat.canSwitchMode)
        card.dot = chatColor(chat.id)
        card.onOpen = { openChat(chat.link) } // the card stays, so you can read the chat and then answer
        card.onClose = { [weak self] in self?.closeApproval(id) }
        card.onAnswer = { [weak self] decision in
            mochiLog("\(decision): clicked on \(chat.title) (\(chat.requestId))")
            self?.answerApproval(chat, decision)
        }
        panel.contentView = glassBackground(for: card, tint: Status.needsInput.color)
        panel.alphaValue = 0

        approvals[id] = panel
        approvalViews[id] = card
        cards.insert(panel, at: 0)
        placeCards()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    /// Takes an Allow and Deny card away, and never offers that tool call again
    func closeApproval(_ id: String) {
        answered.insert(id)
        approvalViews.removeValue(forKey: id)
        guard let panel = approvals.removeValue(forKey: id) else { return }
        dismiss(panel)
    }

    /// F7 allows and F8 denies the request of the chat that has waited longest for your OK: the one nearest its time limit
    func answerWaiting(_ decision: String) {
        let target = keyTarget(chats, showing: Set(approvals.keys), testID: testChat?.requestId)
        guard let chat = target.chat else {
            if target.waiting > 1 {
                mochiLog("\(decision): \(target.waiting) cards showing, not answered")
                showCard(title: "\(target.waiting) chats are waiting", body: "Click Allow or Deny on the one you mean.",
                         color: Status.needsInput.color, link: nil)
            } else {
                mochiLog("\(decision): no card showing, nothing to answer")
            }
            return
        }
        // A chat started before the plugin could switch modes would ignore Accept edits and Auto: say so instead
        if decision == "acceptEdits" || decision == "auto", !chat.canSwitchMode, chat.id != "mochi-test" {
            mochiLog("\(decision): \(chat.title) runs an older plugin that cannot switch modes, not answered")
            showCard(title: "\(chat.title) can't switch modes", body: "Start a new chat to load the latest plugin. Allow and Deny still work.",
                     color: Status.blocked.color, link: chat.link)
            return
        }
        mochiLog("\(decision): answering \(chat.title) (\(chat.requestId))")
        answerApproval(chat, decision)
    }

    /// Writes your answer for the chat's waiting tool call; the plugin picks it up and carries on
    func answerApproval(_ chat: Chat, _ decision: String) {
        if chat.id == "mochi-test" { finishTest(chat, decision); return }
        recordAnswer(&dayLog, day: dayKey(Date()), allowed: decision != "deny")
        dayLogDirty = true
        let answer: [String: Any] = [
            "requestId": chat.requestId, "decision": decision, "at": Date().timeIntervalSince1970 * 1000,
        ]
        writeJSON(answer, to: mochiFolder.appendingPathComponent("answers/\(chat.id).json"))
        closeApproval(chat.requestId)
    }

    /// Starts the pretend request: her real Allow and Deny card appears for 20 seconds, and the keys answer it
    /// Opens the morning brief on demand, the same card as at 8:00 AM
    @objc func menuMorningBrief() { showBrief("morning", now: Date()) }

    /// The pin on the brief card: pins it above other windows, or lets it sit at the usual level again
    func toggleBriefOnTop() {
        briefOnTop.toggle()
        briefPanel.level = briefLevel(pinned: briefOnTop)
        currentBrief?.pinned = briefOnTop
        currentBrief?.needsDisplay = true
    }

    @objc func menuTestApproval() {
        mochiLog("test request started from the menu")
        let now = Date().timeIntervalSince1970 * 1000
        let id = "test-\(Int(now))"
        // askedAt is in the future, so the card lasts 20 seconds instead of 7
        testChat = Chat(id: "mochi-test", title: "Mochi test", status: .needsInput, log: [], updatedAt: now, link: nil,
                        waiting: "Test", isRecent: true, requestId: id, askedAt: now + 13_000,
                        detail: "$ echo hello (a test: nothing runs)", mode: "", canSwitchMode: true)
        look()
        DispatchQueue.main.asyncAfter(deadline: .now() + 21) { [weak self] in
            if self?.testChat?.requestId == id { self?.testChat = nil }
        }
    }

    /// The key or button you pressed on the pretend request: shows what you chose, approves nothing,
    /// and for Auto shows the sparkles for 10 seconds
    func finishTest(_ chat: Chat, _ decision: String) {
        mochiLog("test answered: \(decision)")
        let names = ["allow": "Allow", "deny": "Deny", "acceptEdits": "Accept edits", "auto": "Auto"]
        closeApproval(chat.requestId)
        showCard(title: "Test: you chose \(names[decision] ?? decision)", body: "The keys work. Nothing was approved.",
                 color: Status.ready.color, link: nil)
        if decision == "auto" {
            testChat = Chat(id: "mochi-test", title: "Mochi test", status: .idle, log: [], updatedAt: Date().timeIntervalSince1970 * 1000,
                            link: nil, waiting: "", isRecent: true, mode: "auto")
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.testChat = nil }
        } else {
            testChat = nil
        }
        look()
    }

    /// Every 20 to 40 minutes she thinks out loud, when nothing needs you and she is not quiet. Otherwise she
    /// tries again in two minutes.
    func maybeThink() {
        let now = Date()
        guard now >= nextThoughtAt, thoughtPanel == nil else { return }
        let quiet = quietAt(until: quietUntil, now: now.timeIntervalSince1970)
        guard approvals.isEmpty, view.status != .needsInput, !quiet, noticeAllowed(.thought, onlyApprovals: onlyApprovals) else {
            nextThoughtAt = now.addingTimeInterval(120)
            return
        }
        nextThoughtAt = now.addingTimeInterval(Double.random(in: 20...40) * 60)
        let ready = chats.filter { $0.status == .ready && $0.isOpen && $0.isRecent }.count
        guard let thought = pickThought(usage: usage, readyChats: ready, now: now,
                                        roll: Double.random(in: 0..<1), factIndex: Int.random(in: 0..<funFacts.count)) else { return }
        showThought(thought)
    }

    /// Her bubble: it fades in above her, stays about six seconds, and goes when you click it
    func showThought(_ thought: Thought) {
        guard cardMayShow(hidden: notificationsHidden) else { return }
        mochiLog("thought: \(thought.big) | \(thought.small)")
        let content = ThoughtView(thought: thought)
        content.onDismiss = { [weak self] in self?.hideThought() }
        let panel = floatingPanel(size: ThoughtView.size)
        panel.hasShadow = true
        panel.contentView = content
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        thoughtPanel = panel
        placeCards() // it takes its place in the stack, so it never covers a card
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak panel] in
            if let panel, self?.thoughtPanel === panel { self?.hideThought() }
        }
    }

    func hideThought() {
        guard let panel = thoughtPanel else { return }
        thoughtPanel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) { [weak self] in
            panel.orderOut(nil)
            self?.placeCards()
        }
    }

    /// The scroll beside her: opens "This week", or closes it when it is open
    func toggleWeek() {
        if let weekPanel, weekPanel.isVisible {
            weekPanel.orderOut(nil)
            self.weekPanel = nil
            placeCards()
            return
        }
        let content = WeekView(log: dayLog, usage: usage, now: Date(), colorFor: { chatColor($0) })
        weekView = content
        content.onClose = { [weak self] in
            self?.weekPanel?.orderOut(nil)
            self?.weekPanel = nil
            self?.placeCards()
        }
        let panel = floatingPanel(size: WeekView.size)
        panel.contentView = makeGlass(size: WeekView.size, content: content, radius: 18)
        panel.orderFrontRegardless()
        weekPanel = panel
        placeCards() // the week panel takes its place in the stack, beside the cards
    }

    /// The chat list (when open) and the cards stack beside Mochi as one block, the list nearest her,
    /// then the newest card. Above her when there is room, otherwise below; the whole block stays on screen
    func placeCards() {
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 12 // room between cards, so their glass edges never touch
        var stack: [NSPanel] = cards
        if bubble.isVisible { stack.insert(bubble, at: 0) }
        if let thoughtPanel { stack.insert(thoughtPanel, at: 0) }
        if let weekPanel, weekPanel.isVisible { stack.insert(weekPanel, at: 0) }
        // The morning brief or wrap-up takes the place nearest her, so it never covers the cards
        let briefShown = briefPanel.isVisible
        if briefShown { stack.insert(briefPanel, at: 0) }
        func stackHeight(_ panels: [NSPanel]) -> CGFloat {
            panels.map { $0.frame.height }.reduce(0, +) + CGFloat(max(panels.count - 1, 0)) * gap
        }
        // A stack taller than the screen cannot fit, and the brief would be pushed off it: the brief then sits under her alone
        let briefAlone = briefShown && stackHeight(stack) > screen.height - 8
        if briefAlone { stack.removeAll { $0 === briefPanel } }
        if briefAlone {
            briefPanel.setFrameOrigin(briefOrigin(under: window.frame, width: briefPanel.frame.width, height: briefPanel.frame.height, screen: screen))
        }
        guard !stack.isEmpty else { return }
        let heights = stack.map { $0.frame.height }
        let total = stackHeight(stack)

        // Above Mochi when there is room, otherwise below; the one with more room wins
        let roomAbove = screen.maxY - window.frame.maxY - 4
        let roomBelow = window.frame.minY - screen.minY - 4
        let goAbove = roomAbove >= total || roomAbove >= roomBelow

        var bottom = goAbove ? window.frame.maxY + 2 : window.frame.minY - 2 - total
        bottom = min(max(bottom, screen.minY + 4), screen.maxY - 4 - total)

        // Above Mochi the nearest item sits lowest; below her it sits highest
        var cursor = goAbove ? bottom : bottom + total
        for (panel, height) in zip(stack, heights) {
            let width = panel.frame.width
            let x = min(max(window.frame.midX - width / 2, screen.minX + 4), screen.maxX - width - 4)
            let y = goAbove ? cursor : cursor - height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            cursor = goAbove ? cursor + height + gap : cursor - height - gap
        }
    }

    /// Turns speech into text with the Mac's own recognition while it runs
final class Dictation {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    var isRunning: Bool { engine.isRunning }

    /// Asks for permission the first time; `onText` gets the words so far, `onStop` runs when listening ends
    func start(onText: @escaping (String) -> Void, onStop: @escaping () -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { DispatchQueue.main.async { onStop() }; return }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard granted, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { onStop(); return }
                    self.begin(with: recognizer, onText: onText, onStop: onStop)
                }
            }
        }
    }

    private func begin(with recognizer: SFSpeechRecognizer, onText: @escaping (String) -> Void, onStop: @escaping () -> Void) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onStop()
            return
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result { onText(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true {
                    self?.stop()
                    onStop()
                }
            }
        }
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
    }
}

/// The small text box for a quick note; it takes the keyboard, and Escape closes it
final class NotePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onSubmit: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    // Return sends the note, even when the text box is not the one taking keys
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onSubmit?() } else { super.keyDown(with: event) }
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
        guard cardMayShow(hidden: notificationsHidden) else { return }
        if bubble.isVisible { bubble.orderOut(nil); placeCards(); return }
        hideBubble?.invalidate()
        view.unread = 0

        fillChatList()
        showList()
        bubbleFrame.scroll.contentView.scroll(to: .zero) // the running chats are at the top
        bubbleFrame.scroll.reflectScrolledClipView(bubbleFrame.scroll.contentView)
    }

    /// Gives the chat list the current chats, and its heading and footer
    func fillChatList() {
        let open = chats.filter(\.isOpen).count
        let needing = chats.filter { $0.status == .needsInput }.count
        let approving = chats.filter(approvingOnItsOwn).count
        chatList.chats = chats
        chatList.usage = usage
        chatList.title = boardTitle(needing: needing)
        chatList.titleColor = view.status.color
        chatList.subtitle = chats.isEmpty ? "No Claude chats yet" : boardSubtitle(approving: approving, open: open)
        chatList.footer = chats.contains(where: { $0.link != nil }) ? "Click a chat to open it in Claude" : nil
        chatList.runningSince = runningSince
        chatList.countdowns = countdowns
        let running = chats.filter { $0.isOpen && $0.status == .running }.map(\.title)
        let finished = chats.filter { $0.status == .ready }.max { $0.updatedAt < $1.updatedAt }
        chatList.activityLines = [
            (runningText(titles: running), ChatListView.runningInk),
            (finishedText(title: finished?.title, updated: finished?.updatedAt), Status.ready.color),
        ]
    }

    /// While the list is open it follows the chats, once a second: a chat starting, working or finishing shows at once.
    /// The bubble only resizes when the list's height changes, so the scroll position holds
    func refreshChatList() {
        guard bubble.isVisible, bubbleFrame.scroll.documentView === chatList else { return }
        fillChatList()
        if chatList.fittingHeight() != chatList.frame.height {
            showList()
        } else {
            chatList.needsDisplay = true
        }
    }

    func showBubble() {
        bubbleFrame.scroll.documentView = bubbleView
        let size = bubbleView.fittingSize(maxWidth: 460)
        // The lines take their full height; the bubble stops growing and scrolls past the cap
        bubble.setContentSize(NSSize(width: size.width + 8, height: min(size.height, bubbleMaxHeight) + 8))
        bubbleView.frame = NSRect(origin: .zero, size: size)
        bubbleFrame.accent = bubbleView.accent
        tintGlass(bubbleGlass, bubbleView.accent)
        bubbleView.scroll(.zero) // start at the top, the newest
        bubbleView.needsDisplay = true
        bubble.invalidateCursorRects(for: bubbleView)
        bubble.acceptsMouseMovedEvents = true // so a chat's line underlines under the pointer
        bubble.orderFrontRegardless()
        placeCards()
    }

    /// Shows her chat list in the bubble, sized to fit, scrolling past the cap
    /// Opens the skin editor for a chat, in the middle of the screen; every pick shows in the list at once
    func showSkinEditor(_ chat: Chat) {
        skinPanel?.orderOut(nil)
        let editor = SkinEditorView(chatID: chat.id, title: chat.title)
        editor.onChange = { [weak self] in self?.chatList.needsDisplay = true }
        editor.onClose = { [weak self] in
            self?.skinPanel?.orderOut(nil)
            self?.skinPanel = nil
        }
        let panel = floatingPanel(size: SkinEditorView.size)
        panel.contentView = makeGlass(size: SkinEditorView.size, content: editor, radius: 20)
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: screen.midX - SkinEditorView.size.width / 2, y: screen.midY - SkinEditorView.size.height / 2))
        panel.level = .statusBar
        panel.orderFrontRegardless()
        skinPanel = panel
        mochiLog("skin editor: opened for \(chat.title)")
    }

    func showList() {
        presentInBubble(chatList, height: chatList.fittingHeight(), width: ChatListView.width, accent: view.status.color)
    }

    /// Shows her usage status box in the bubble
    func showUsagePanel(accent: NSColor) {
        presentInBubble(usagePanel, height: usagePanel.fittingHeight(), width: UsagePanelView.width, accent: accent)
    }

    /// Puts a view in the bubble at its size: the glass, its content and the scroll view all take the same size
    func presentInBubble(_ content: NSView, height: CGFloat, width: CGFloat, accent: NSColor) {
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        bubbleFrame.scroll.documentView = content
        let size = NSSize(width: width + 8, height: min(height, bubbleMaxHeight) + 8)
        bubble.setContentSize(size)
        bubbleGlass.frame = NSRect(origin: .zero, size: size)
        bubbleFrame.frame = NSRect(origin: .zero, size: size)
        bubbleFrame.accent = accent
        tintGlass(bubbleGlass, accent)
        content.needsDisplay = true
        bubble.orderFrontRegardless()
        mochiLog("bubble: shown \(Int(width))x\(Int(height)) at \(bubble.frame), content \(content.frame), scroll \(bubbleFrame.scroll.documentView?.frame ?? .zero)")
        placeCards()
    }

    /// The chat list and the cards share one place beside Mochi, so they never cover each other
    func placeBubble() { placeCards() }

    // MARK: - Quick note and talk

    lazy var noteField: NSTextField = {
        let field = NSTextField(frame: NSRect(x: 12, y: 9, width: 256, height: 22))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Write a note to start a session"
        field.target = self
        field.action = #selector(sendNote)
        return field
    }()

    lazy var note: NotePanel = {
        let size = NSSize(width: 280, height: 40)
        let panel = NotePanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.addSubview(noteField)
        panel.contentView = makeGlass(size: size, content: box, radius: 14)
        panel.onCancel = { [weak self] in self?.closeNote() }
        panel.onSubmit = { [weak self] in self?.sendNote() }
        return panel
    }()

    let dictation = Dictation()

    /// The pencil button: opens the note box, or closes it if it is open
    func toggleNote() {
        if note.isVisible { closeNote(); return }
        placeNote()
        NSApp.activate(ignoringOtherApps: true)
        note.makeKeyAndOrderFront(nil)
        note.makeFirstResponder(noteField)
        view.forceShow = true
        view.needsDisplay = true
    }

    /// Stops listening and hides the note box; whatever was written stays in it
    func closeNote() {
        dictation.stop()
        setRecording(false)
        note.orderOut(nil)
        view.forceShow = false
        view.needsDisplay = true
    }

    /// The microphone button: types what you say into the note box, until you press it again or send
    func toggleTalk() {
        if dictation.isRunning { dictation.stop(); setRecording(false); return }
        if !note.isVisible { toggleNote() }
        let before = noteField.stringValue
        setRecording(true)
        dictation.start(onText: { [weak self] words in
            guard let self else { return }
            self.noteField.stringValue = [before, words].filter { !$0.isEmpty }.joined(separator: " ")
        }, onStop: { [weak self] in self?.setRecording(false) })
        // The microphone press can take the keys away from the box; hand them back so Enter still sends
        NSApp.activate(ignoringOtherApps: true)
        note.makeKeyAndOrderFront(nil)
        note.makeFirstResponder(noteField)
    }

    func setRecording(_ on: Bool) {
        view.recording = on
        view.needsDisplay = true
    }

    /// Shows the brief under her, centred, kept on screen, until you close it with its cross
    func showBrief(_ kind: String, now: Date) {
        // The wrap-up is for the end of the day: before 6:00 PM it stays hidden, even when opened by hand
        if kind == "evening", !wrapUpDue(now: now) {
            mochiLog("brief: wrap-up held until 6:00 PM")
            return
        }
        presentUnderHer(briefContent(kind: kind, chats: chats, log: dayLog, now: now, offer: resetOffer, usagePercent: usage?.fiveHour), live: kind)
        mochiLog("brief: \(kind) shown")
    }

    /// The agents running now, each with its task, how long it has run and when it last did something
    func showAgents() {
        let now = Date()
        let lines: [(String, NSColor)] = view.activeAgents.map { run in
            let minutes = Int(now.timeIntervalSince(run.started) / 60)
            let quiet = Int(now.timeIntervalSince(run.lastActivity))
            return ("\(run.task) · \(max(1, minutes)) min · active \(quiet) s ago", Status.running.color)
        }
        var content = BriefContent()
        content.title = "Agents running"
        content.lines = lines.isEmpty ? [("No agent is running right now", .labelColor)] : lines
        presentUnderHer(content)
        mochiLog("agents: \(lines.count) shown")
    }

    /// Puts a card under her, centred and kept on screen, until its cross closes it
    func presentUnderHer(_ content: BriefContent, live kind: String? = nil) {
        let brief = BriefView(frame: NSRect(x: 0, y: 0, width: BriefView.width, height: 120))
        brief.content = content
        let height = brief.fittingHeight()
        brief.frame = NSRect(x: 0, y: 0, width: BriefView.width, height: height)
        brief.onClose = { [weak self] in self?.briefPanel.orderOut(nil); self?.briefLiveKind = nil; self?.placeCards() }
        brief.pinned = briefOnTop
        brief.onPin = { [weak self] in self?.toggleBriefOnTop() }
        briefPanel.contentView = makeGlass(size: NSSize(width: BriefView.width, height: height), content: brief, radius: 20)
        briefPanel.setContentSize(NSSize(width: BriefView.width, height: height))
        briefPanel.acceptsMouseMovedEvents = true
        currentBrief = brief
        briefLiveKind = kind
        briefPanel.level = briefLevel(pinned: briefOnTop)
        briefPanel.orderFrontRegardless()
        placeCards() // the brief joins the stack, so the cards move aside for it
    }

    /// While the morning brief or the wrap-up is open, its numbers and lists update every second
    func refreshBrief() {
        guard let kind = briefLiveKind, briefPanel.isVisible, let brief = currentBrief else { return }
        brief.content = briefContent(kind: kind, chats: chats, log: dayLog, now: Date(), offer: resetOffer, usagePercent: usage?.fiveHour)
        let height = brief.fittingHeight()
        if height != briefPanel.frame.height {
            brief.frame = NSRect(x: 0, y: 0, width: BriefView.width, height: height)
            briefPanel.setContentSize(NSSize(width: BriefView.width, height: height))
            placeBrief()
        }
        brief.needsDisplay = true
    }

    /// The brief hides on its own until the pointer comes near Mochi or the brief; closing it with the cross ends this
    func refreshBriefVisibility() {
        guard briefLiveKind != nil else { return }
        let near = pointerNearBrief(pointer: NSEvent.mouseLocation, mochi: window.frame,
                                    brief: briefPanel.isVisible ? briefPanel.frame : .zero, margin: 80)
        if near, !briefPanel.isVisible {
            briefPanel.orderFrontRegardless()
            placeCards()
        } else if !near, briefPanel.isVisible {
            briefPanel.orderOut(nil)
            placeCards()
        }
    }

    /// Keeps the week panel's chart in step with the day record while it is open
    func refreshWeek() {
        guard let weekView, let weekPanel, weekPanel.isVisible else { return }
        weekView.update(log: dayLog, usage: usage, now: Date())
    }

    /// Keeps the brief card centred under her, so it moves with her
    func placeBrief() {
        placeCards()
        mochiLog("brief: placed at \(briefPanel.frame.origin) under mochi \(window.frame)")
    }

    /// Sends the note as a new Claude Code session; Claude opens with it written in
    @objc func sendNote() {
        let text = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "claude://code/new?source=mochi&q=\(encoded)") else { return }
        closeNote()
        noteField.stringValue = ""
        NSWorkspace.shared.open(url)
    }

    /// Under the buttons, near the pencil, so the box opens where you pressed; above Mochi when there is no room below
    func placeNote() {
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = note.frame.size
        var x = window.frame.minX + 4
        var y = window.frame.minY - size.height - 4
        if y < screen.minY + 4 { y = window.frame.maxY + 4 }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        note.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        // The shortcuts in one submenu, so the top of the menu stays clean
        let shortcuts = NSMenu()
        for line in ["Quick note    F5", "Talk    F6", "Jump to the chat that needs you    ⌥J"] {
            shortcuts.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false
        }
        let approvalLines = approvalShortcutLines(keyTarget(chats, showing: Set(approvals.keys), testID: testChat?.requestId).chat)
        if !approvalLines.isEmpty {
            shortcuts.addItem(.separator())
            for line in approvalLines { shortcuts.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false }
        }
        shortcuts.addItem(.separator())
        shortcuts.addItem(withTitle: "Test the approval keys", action: #selector(menuTestApproval), keyEquivalent: "").target = self
        let shortcutsItem = menu.addItem(withTitle: "Shortcuts", action: nil, keyEquivalent: "")
        shortcutsItem.submenu = shortcuts
        menu.addItem(.separator())
        if let usage = Usage.read() {
            menu.addItem(withTitle: "Usage: 5-hour \(usage.fiveHour)% · week \(usage.week)% (\(ago(usage.at)))", action: nil, keyEquivalent: "").isEnabled = false
            if let back = usage.backText { menu.addItem(withTitle: "⏳ \(back)", action: nil, keyEquivalent: "").isEnabled = false }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Morning brief", action: #selector(menuMorningBrief), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close all boxes", action: #selector(menuCloseAllBoxes), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show notifications", action: #selector(menuNotifications), keyEquivalent: "").target = self
        let hideItem = menu.addItem(withTitle: "Hide notifications", action: #selector(menuToggleHideNotifications), keyEquivalent: "")
        hideItem.target = self
        hideItem.state = notificationsHidden ? .on : .off
        let onlyItem = menu.addItem(withTitle: "Only tell me when something needs my approval", action: #selector(menuToggleOnlyApprovals), keyEquivalent: "")
        onlyItem.target = self
        onlyItem.state = onlyApprovals ? .on : .off
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
        let approve = menu.addItem(withTitle: "Allow or deny from Mochi", action: #selector(menuToggleApprove), keyEquivalent: "")
        approve.target = self
        approve.state = approveHere ? .on : .off
        let soundItem = menu.addItem(withTitle: "Sound when a chat needs you", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        for name in Self.sounds + ["None"] {
            let item = soundMenu.addItem(withTitle: name, action: #selector(menuPickSound(_:)), keyEquivalent: "")
            item.target = self
            item.state = name == needsSound ? .on : .off
        }
        soundItem.submenu = soundMenu
        let now = Date().timeIntervalSince1970
        if quietAt(until: quietUntil, now: now) {
            let ends = quietEndsText(until: quietUntil)
            let title = ends.isEmpty ? "Sounds back on" : "Sounds back on (quiet until \(ends))"
            menu.addItem(withTitle: title, action: #selector(menuSetQuiet(_:)), keyEquivalent: "").target = self
        } else {
            let hour = menu.addItem(withTitle: "Quiet for 1 hour", action: #selector(menuSetQuiet(_:)), keyEquivalent: "")
            hour.target = self
            hour.tag = 1
            let forever = menu.addItem(withTitle: "Quiet until I turn sounds back on", action: #selector(menuSetQuiet(_:)), keyEquivalent: "")
            forever.target = self
            forever.tag = 2
        }
        let offerTitle = resetOffer == nil ? "Add a reset offer…" : "Change reset offer…"
        menu.addItem(withTitle: offerTitle, action: #selector(menuResetOffer), keyEquivalent: "").target = self
        if resetOffer != nil {
            menu.addItem(withTitle: "Remove reset offer", action: #selector(menuRemoveResetOffer), keyEquivalent: "").target = self
        }
        let login = menu.addItem(withTitle: "Open at login", action: #selector(menuToggleLogin), keyEquivalent: "")
        login.target = self
        login.state = opensAtLogin ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Mochi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func menuToggleNotifications() { macNotifications.toggle() }

    /// Turns Allow and Deny on or off; with it off, the plugin never waits for her
    @objc func menuToggleApprove() { approveHere.toggle(); syncApprovals() }

    @objc func menuToggleLogin() { setOpensAtLogin(!opensAtLogin) }

    /// Only approvals pop up, or everything: finished work, usage warnings and her thoughts too
    @objc func menuToggleOnlyApprovals() {
        onlyApprovals.toggle()
        mochiLog("notices: only approvals \(onlyApprovals ? "on" : "off")")
    }

    /// Puts on the chosen skin at once and remembers it
    @objc func menuPickSkin(_ item: NSMenuItem) {
        skinIndex = item.tag
        skinPicked = true
        view.needsDisplay = true
    }

    /// Picks the "needs you" sound and plays it once so you hear it
    @objc func menuPickSound(_ item: NSMenuItem) {
        needsSound = item.title
        playNeedsSound()
    }

    /// Quiet for an hour (tag 1), quiet until you turn her back on (tag 2), or sounds back on (any other tag, when she is quiet).
    /// Quiet means no sounds, and no cards or Mac notifications for finished work
    @objc func menuSetQuiet(_ item: NSMenuItem) {
        if quietAt(until: quietUntil, now: Date().timeIntervalSince1970) {
            quietUntil = 0
            mochiLog("quiet: ended from the menu")
        } else if item.tag == 2 {
            quietUntil = quietForever
            mochiLog("quiet: until turned back on, from the menu")
        } else {
            quietUntil = Date().timeIntervalSince1970 + 3600
            mochiLog("quiet: for an hour, from the menu")
        }
    }

    /// Asks for a reset offer as "yyyy-mm-dd, count", the day to use it by and how many resets you have
    @objc func menuResetOffer() {
        let alert = NSAlert()
        alert.messageText = "Reset offer"
        alert.informativeText = "Type the last day to use it, as yyyy-mm-dd, then a comma and how many resets you have."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "2026-10-22, 1"
        if let resetOffer {
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            field.stringValue = "\(day.string(from: resetOffer.useBy)), \(resetOffer.count)"
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let offer = parseResetOffer(field.stringValue) else {
            mochiLog("reset offer: could not read \(field.stringValue)")
            showCard(title: "Reset offer not saved", body: "Type a date and a count, like 2026-10-22, 1", color: Status.blocked.color, link: nil)
            return
        }
        resetOffer = offer
        mochiLog("reset offer: \(offer.count) until \(offer.useBy)")
    }

    /// Takes the reset offer off the box
    @objc func menuRemoveResetOffer() {
        resetOffer = nil
        mochiLog("reset offer: removed")
    }

    @objc func menuNotifications() { if !bubble.isVisible { toggleNotifications() } }

    /// Closes every open box: the brief, the week panel, the chat list, her thoughts and the cards
    @objc func menuCloseAllBoxes() {
        briefPanel.orderOut(nil)
        briefLiveKind = nil
        weekPanel?.orderOut(nil)
        weekPanel = nil
        bubble.orderOut(nil)
        thoughtPanel?.orderOut(nil)
        for panel in cards { panel.orderOut(nil) }
        cards.removeAll()
        placeCards()
    }

    /// Hides every notification card, the chat list and her thoughts; hiding closes the ones on screen now
    @objc func menuToggleHideNotifications() {
        notificationsHidden.toggle()
        guard notificationsHidden else { return }
        for panel in cards { panel.orderOut(nil) }
        cards.removeAll()
        bubble.orderOut(nil)
        placeCards()
    }

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
