// Mochi Studio: change how Mochi looks. Saves to ~/.claude/mochi/look.json, which Mochi reads
// every second, so a change shows at once.
import SwiftUI

struct Look: Codable, Equatable {
    var body: String = "F4A259"      // hex, without the #
    var eyes: String = "round"       // round | sleepy
    var accessory: String = "none"   // none | bow | hat | scarf
    var name: String = "Mochi"
    var speed: Double = 1.0          // 0.5 slow ... 2 fast

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

func color(_ hex: String) -> Color {
    var v: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&v)
    return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
}

let swatches = ["F4A259", "3A3A48", "F5F7FA", "8FD9B6", "B197FC", "FF8FAB", "74C0FC", "FFD43B"]

/// The pixel cat, drawn the same way Mochi draws it: 16 by 16 squares, with accessories on top
struct Preview: View {
    let look: Look
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 16
            let ox = (size.width - 16 * s) / 2, oy = (size.height - 16 * s) / 2
            let outline = color("3B2A20"), belly = color("FFE0B5"), ear = color("FF8FAB"), stripe = color("D9822B")
            let body = color(look.body), eye = color("2B2118")
            for (y, row) in mochiGrid.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    var fill: Color
                    switch ch {
                    case "K": fill = outline
                    case "B": fill = body
                    case "L": fill = belly
                    case "P": fill = ear
                    case "D": fill = stripe
                    case "E", "W": fill = look.eyes == "sleepy" ? body : (ch == "W" ? .white : eye)
                    case "e": fill = eye
                    default: fill = .black
                    }
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

/// Holds the look being edited. Plain property wrappers, so it builds without Xcode's macro plugins.
final class Model: ObservableObject {
    @Published var look = Look.load()
    @Published var saved = Look.load()
}

struct ContentView: View {
    @StateObject private var model = Model()

    private var look: Look { model.look }
    private func edit(_ change: (inout Look) -> Void) {
        var copy = model.look
        change(&copy)
        model.look = copy
    }

    var body: some View {
        HStack(spacing: 0) {
            Form {
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
            .frame(width: 400, height: 520)
        }
        .frame(height: 520)
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
