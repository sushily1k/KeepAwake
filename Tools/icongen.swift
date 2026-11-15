import Cocoa

let outDir = CommandLine.arguments[1]

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    let rect = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    let gradient = NSGradient(starting: NSColor(red: 0.60, green: 0.36, blue: 0.20, alpha: 1),
                              ending: NSColor(red: 0.26, green: 0.14, blue: 0.08, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    if let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let img = symbol.withSymbolConfiguration(config) {
            let sz = img.size
            img.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2,
                                width: sz.width, height: sz.height))
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (px, name) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
