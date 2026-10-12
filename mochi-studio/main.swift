// Mochi Studio: change how Mochi looks. Saves to ~/.claude/mochi/look.json, which Mochi reads
// every second, so a change shows at once.
import SwiftUI
import AppKit

struct Look: Codable, Equatable {
    var body: String = "F4A259"      // hex, without the #
    var eyes: String = "round"       // round | sleepy
    var accessory: String = "none"   // none | bow | hat | scarf
    var name: String = "Mochi"
    var speed: Double = 1.0          // 0.5 slow ... 2 fast
    var pixels: [String]? = nil      // a square of letters, one row per line, when painted by hand
    var detail: Int = 16             // how many squares across the default cat is drawn with: 16 or 32

    /// The grid Mochi draws: the painted one when it is valid, otherwise the default at this detail
    var art: [String] {
        guard let pixels, (8...64).contains(pixels.count), pixels.allSatisfy({ $0.count == pixels.count }) else {
            return resample(mochiGrid, to: detail)
        }
        return pixels
    }

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/mochi/look.json")

    static func load() -> Look {
        guard let data = try? Data(contentsOf: file),
              let look = try? JSONDecoder().decode(Look.self, from: data) else { return Look() }
        return look
    }

    func save() {
        try? FileManager.default.createDirectory(at: Look.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Look.file)
    }
}

let mochiGrid = [
    "................", "..K..........K..", ".KBK........KBK.", ".KPBK......KBPK.",
    ".KBBBKKKKKKBBBK.", ".KBBBBBBBBBBBBK.", "KBBLBBBBBBBBLBBK", "KBBEWBBBBBBEWBBK",
    "KBBeeBBBBBBeeBBK", "KBPBBBBKKBBBBPBK", "KBBBBBBBBBBBBBBK", ".KBBDBBBBBBDBBK.",
    "..KKBBLLLLBBKK..", "..KBBKBLLBKBBK..", "..KBBK.KK.KBBK..", "...KK......KK...",
]

/// The drawing on a finer or rougher grid, each square copied from the nearest place in the old one.
/// Nothing is bent or smoothed, so the shapes keep their true proportions.
func resample(_ rows: [String], to n: Int) -> [String] {
    let m = rows.count
    if n == m { return rows }
    let src = rows.map { Array($0) }
    return (0..<n).map { y in String((0..<n).map { x in src[y * m / n][x * m / n] }) }
}

func color(_ hex: String) -> Color {
    var v: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&v)
    return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
}

let swatches = ["F4A259", "3A3A48", "F5F7FA", "8FD9B6", "B197FC", "FF8FAB", "74C0FC", "FFD43B"]

/// The letters you can paint with, and what each one is
let paints: [Character] = ["K", "B", "L", "P", "D", "E", "W", "e", "."]
let paintNames: [Character: String] = [
    "K": "Outline", "B": "Body", "L": "Belly and paws", "P": "Ears and cheeks", "D": "Nose and stripes",
    "E": "Eyes", "W": "Eye shine", "e": "Closed eyes", ".": "Erase",
]

/// The colour a letter is drawn in, or nil for an empty square
func pixelFill(_ ch: Character, _ look: Look) -> Color? {
    switch ch {
    case "K": return color("3B2A20")
    case "B": return color(look.body)
    case "L": return color("FFE0B5")
    case "P": return color("FF8FAB")
    case "D": return color("D9822B")
    case "E": return look.eyes == "sleepy" ? color(look.body) : color("2B2118")
    case "W": return look.eyes == "sleepy" ? color(look.body) : .white
    case "e": return color("2B2118")
    case ".": return nil
    default: return .black
    }
}

/// The pixel cat, drawn the same way Mochi draws it: 16 by 16 squares, with accessories on top
struct Preview: View {
    let look: Look
    var body: some View {
        Canvas { ctx, size in
            let n = CGFloat(look.art.count)
            let s = min(size.width, size.height) / n
            let ox = (size.width - n * s) / 2, oy = (size.height - n * s) / 2
            for (y, row) in look.art.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let fill = pixelFill(ch, look) else { continue }
                    ctx.fill(Path(CGRect(x: ox + CGFloat(x) * s, y: oy + CGFloat(y) * s, width: s, height: s)), with: .color(fill))
                }
            }
            // Accessories sit on the cat's head or neck
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
            }
            switch look.accessory {
            case "bow":
                ctx.fill(Path(ellipseIn: box(5, 1.5, 3, 2.5)), with: .color(color("1C7ED6")))
                ctx.fill(Path(ellipseIn: box(8, 1.5, 3, 2.5)), with: .color(color("1C7ED6")))
            case "hat":
                ctx.fill(Path(box(4, -1, 8, 1.2)), with: .color(color("3A3A48")))
                ctx.fill(Path(box(5.5, -4, 5, 3.2)), with: .color(color("3A3A48")))
            case "scarf":
                ctx.fill(Path(box(3, 11, 10, 1.6)), with: .color(color("E03131")))
                ctx.fill(Path(box(10, 12.2, 2, 2.2)), with: .color(color("E03131")))
            default: break
            }
        }
    }
}

/// The same colours as a native colour, for drawing the square you paint on
func nsColor(_ ch: Character, _ look: Look) -> NSColor? {
    guard let fill = pixelFill(ch, look) else { return nil }
    return NSColor(fill)
}

/// The square you paint on. A plain mouse view, so clicks and drags reach it even inside the scrolling form.
final class PixelGridView: NSView {
    var look = Look()
    var onPaint: ((Int, Int) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    /// A click paints straight away, even when the window was not in front
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let n = look.art.count
        let s = bounds.width / CGFloat(n)
        for (y, row) in look.art.enumerated() {
            for (x, ch) in row.enumerated() {
                let rect = NSRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)
                (nsColor(ch, look) ?? NSColor.secondaryLabelColor.withAlphaComponent(0.12)).setFill()
                rect.fill()
            }
        }
        // Thin lines between squares, so a finer grid is easy to see and paint
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let lines = NSBezierPath()
        for i in 0...n {
            let at = (CGFloat(i) * s).rounded() + 0.5
            lines.move(to: NSPoint(x: at, y: 0)); lines.line(to: NSPoint(x: at, y: bounds.height))
            lines.move(to: NSPoint(x: 0, y: at)); lines.line(to: NSPoint(x: bounds.width, y: at))
        }
        lines.lineWidth = 0.5
        lines.stroke()
    }

    override func mouseDown(with event: NSEvent) { paint(event) }
    override func mouseDragged(with event: NSEvent) { paint(event) }

    private func paint(_ event: NSEvent) {
        let n = look.art.count
        let s = bounds.width / CGFloat(n)
        let p = convert(event.locationInWindow, from: nil)
        let x = Int(p.x / s), y = Int(p.y / s)
        if (0..<n).contains(x) && (0..<n).contains(y) { onPaint?(x, y) }
    }
}

/// Puts the native grid into SwiftUI, at a fixed square size
struct PixelEditor: NSViewRepresentable {
    let look: Look
    let onPaint: (Int, Int) -> Void
    private let side: CGFloat = 240 // the same size as the preview, so one square matches the sample

    func makeNSView(context: Context) -> PixelGridView {
        let view = PixelGridView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.onPaint = onPaint
        return view
    }

    func updateNSView(_ view: PixelGridView, context: Context) {
        view.look = look
        view.onPaint = onPaint
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PixelGridView, context: Context) -> CGSize? {
        CGSize(width: side, height: side)
    }
}

/// Holds the look being edited. Plain property wrappers, so it builds without Xcode's macro plugins.
final class Model: ObservableObject {
    @Published var look = Look.load()
    @Published var saved = Look.load()
    /// The letter the pixel editor paints with
    @Published var paint: Character = "B"
}

struct ContentView: View {
    @StateObject private var model = Model()

    private var look: Look { model.look }
    private func edit(_ change: (inout Look) -> Void) {
        var copy = model.look
        change(&copy)
        model.look = copy
    }

    /// Puts one letter into one square of the painted grid
    private func paintSquare(_ x: Int, _ y: Int) {
        let letter = model.paint
        guard model.look.art.indices.contains(y), model.look.art[y].count > x else { return }
        edit {
            var rows = $0.art
            var cells = Array(rows[y])
            guard cells[x] != letter else { return }
            cells[x] = letter
            rows[y] = String(cells)
            $0.pixels = rows
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Pixels") {
                    Picker("Fineness", selection: Binding(get: { look.art.count }, set: { n in
                        let old = look.art
                        edit {
                            $0.detail = n
                            $0.pixels = resample(old, to: n)
                        }
                    })) {
                        Text("Rough").tag(16)
                        Text("Fine").tag(32)
                    }
                    .pickerStyle(.segmented)
                    PixelEditor(look: look, onPaint: paintSquare)
                        .frame(width: 240, height: 240)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 4) {
                        ForEach(paints, id: \.self) { ch in
                            Button { model.paint = ch } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                                    if let fill = pixelFill(ch, look) {
                                        RoundedRectangle(cornerRadius: 4).fill(fill)
                                    } else {
                                        Image(systemName: "eraser").font(.system(size: 11))
                                    }
                                }
                                .frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary, lineWidth: model.paint == ch ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .help(paintNames[ch] ?? "")
                        }
                    }
                    Text(paintNames[model.paint] ?? "").font(.caption).foregroundStyle(.secondary)
                    Button("Reset pixels") { edit { $0.pixels = nil } }
                        .disabled(look.pixels == nil)
                }
                Section("Body colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 4), spacing: 10) {
                        ForEach(swatches, id: \.self) { hex in
                            Circle().fill(color(hex)).frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color.primary, lineWidth: look.body == hex ? 2.5 : 0).padding(-4))
                                .onTapGesture { edit { $0.body = hex } }
                        }
                    }
                }
                Section("Eyes") {
                    Picker("Style", selection: Binding(get: { look.eyes }, set: { v in edit { $0.eyes = v } })) {
                        Text("Round").tag("round")
                        Text("Sleepy").tag("sleepy")
                    }.pickerStyle(.segmented)
                }
                Section("Accessory") {
                    Picker("Wear", selection: Binding(get: { look.accessory }, set: { v in edit { $0.accessory = v } })) {
                        Text("None").tag("none")
                        Text("Bow").tag("bow")
                        Text("Hat").tag("hat")
                        Text("Scarf").tag("scarf")
                    }.pickerStyle(.segmented)
                }
                Section("Name") {
                    TextField("Name", text: Binding(get: { look.name }, set: { v in edit { $0.name = v } }))
                }
                Section("Walking speed") {
                    Slider(value: Binding(get: { look.speed }, set: { v in edit { $0.speed = v } }), in: 0.5...2, step: 0.25)
                    Text(String(format: "%.2f×", look.speed)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 320)

            VStack(spacing: 16) {
                Text("Preview").font(.headline)
                Preview(look: look)
                    .frame(width: 240, height: 240)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.91, green: 0.96, blue: 1.0)))
                Text(look.name).font(.title3.bold())
                Spacer()
                HStack {
                    Button("Reset") { model.look = Look() }
                    Spacer()
                    Button("Save") {
                        model.look.save()
                        model.saved = model.look
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(look == model.saved)
                }
            }
            .padding(24)
            .frame(width: 400, height: 800)
        }
        .frame(height: 800)
    }
}

@main
struct MochiStudioApp: App {
    var body: some Scene {
        WindowGroup("Mochi Studio") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
