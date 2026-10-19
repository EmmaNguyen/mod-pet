// Mochi Studio's screenshot renderer. media/snapshots.sh appends this file to mochi-studio/main.swift (without its
// last lines, which start the app) and draws the real window content off screen. Studio opens with the look saved in
// ~/.claude/mochi/look.json; snapshots.sh points that path at a pretend home holding a sample look, so the picture
// never shows the look saved on the Mac that renders it. The window is its real size: the form scrolls below Eyes.

_ = NSApplication.shared
NSApp.appearance = NSAppearance(named: .aqua)

guard CommandLine.arguments.count > 1 else {
    print("usage: studio-snapshot <output file>")
    exit(2)
}

let hosting = NSHostingView(rootView: ContentView())
let size = hosting.fittingSize
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .aqua)
window.contentView = hosting
hosting.frame = NSRect(origin: .zero, size: size)
hosting.layoutSubtreeIfNeeded()
RunLoop.current.run(until: Date().addingTimeInterval(0.6))

let factor: CGFloat = 2
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * factor), pixelsHigh: Int(size.height * factor),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = size
hosting.cacheDisplay(in: hosting.bounds, to: rep)

// The window background is drawn by the window, not the view, so lay the picture over it
let image = NSImage(size: size)
image.addRepresentation(rep)
let flat = NSImage(size: size, flipped: false) { rect in
    NSColor.windowBackgroundColor.setFill()
    rect.fill()
    image.draw(in: rect)
    return true
}
guard let tiff = flat.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1]) \(Int(size.width * factor))x\(Int(size.height * factor))")
