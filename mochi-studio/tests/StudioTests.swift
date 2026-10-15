// Mochi Studio's logic tests. test.sh appends this file to main.swift (without @main and the app), so these
// run against the real code. Nothing here saves a look.

func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { exit(1) }
}

// Reading saved looks
let partial = try! JSONDecoder().decode(Look.self, from: #"{"body":"8FD9B6","eyes":"sleepy"}"#.data(using: .utf8)!)
check("a look with missing settings keeps the rest", partial.body == "8FD9B6" && partial.eyes == "sleepy" && partial.accessory == "none" && partial.detail == 16)
let row = "\"" + String(repeating: "B", count: 32) + "\""
let fine = try! JSONDecoder().decode(Look.self, from: "{\"pixels\":[\(Array(repeating: row, count: 32).joined(separator: ","))]}".data(using: .utf8)!)
check("a painted fine look without a fineness opens as Fine", fine.detail == 32)
var sample = Look(); sample.body = "B197FC"; sample.accessory = "hat"
check("saving and loading keeps everything", (try! JSONDecoder().decode(Look.self, from: JSONEncoder().encode(sample))) == sample)

// Resampling to a finer grid copies squares, so shapes keep their proportions
check("Fine is 32 squares across", resample(mochiGrid, to: 32).count == 32 && resample(mochiGrid, to: 32)[0].count == 32)
check("Fine copies each square into four", Array(resample(mochiGrid, to: 32)[2])[4] == Array(mochiGrid[1])[2])

// Undo and redo
let m = Model()
let start = m.look
m.change { $0.detail = 32; $0.pixels = resample(mochiGrid, to: 32) }
check("a fineness change is one step", m.undoSteps.count == 1)
m.beginStroke()
for x in 0..<5 { var rows = m.look.art; var cells = Array(rows[0]); cells[x] = "K"; rows[0] = String(cells); m.look.pixels = rows }
m.endStroke()
check("a whole paint stroke is one step", m.undoSteps.count == 2)
let painted = m.look
m.undo(); check("undo takes back the stroke", m.look.art.count == 32 && m.look != painted)
m.undo(); check("undo again takes back the fineness", m.look == start)
m.redo(); m.redo(); check("redo returns both", m.look == painted)
m.rename("M"); m.rename("Mo"); m.rename("Moc")
check("typing a name is one step", m.undoSteps.count == 3)
m.beginStroke(); m.endStroke()
check("a stroke that changed nothing is not a step", m.undoSteps.count == 3)
for i in 0..<120 { m.change { $0.name = "n\(i)" } }
check("history keeps the last 100 steps", m.undoSteps.count == 100)

print("ALL PASSED")
