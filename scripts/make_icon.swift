// Генерує Resources/AppIcon.icns: скруглений квадрат з градієнтом + SF Symbol.
// Запуск: swift scripts/make_icon.swift <iconset-робоча-тека> <вихідний.icns шлях без iconutil>
// (iconutil викликає build-скрипт; тут лише PNG-и iconset)
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fatalError("usage: swift make_icon.swift <output.iconset dir>")
}
let iconsetDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let px = CGFloat(pixels)
    let margin = px * 0.055
    let rect = NSRect(x: margin, y: margin, width: px - margin * 2, height: px - margin * 2)
    let radius = rect.width * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.62, blue: 0.42, alpha: 1.0),
        NSColor(calibratedRed: 0.05, green: 0.36, blue: 0.65, alpha: 1.0),
    ])
    gradient?.draw(in: path, angle: -60)

    let config = NSImage.SymbolConfiguration(pointSize: px * 0.46, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let scale = (rect.width * 0.62) / max(symbolSize.width, symbolSize.height)
        let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
        let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        symbol.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero, operation: .sourceOver, fraction: 1.0
        )
    }
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { fatalError("no rep") }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try! png.write(to: url)
}

for base in [16, 32, 128, 256, 512] {
    writePNG(renderIcon(pixels: base), pixels: base,
             to: iconsetDir.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(renderIcon(pixels: base * 2), pixels: base * 2,
             to: iconsetDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("iconset готовий: \(iconsetDir.path)")
