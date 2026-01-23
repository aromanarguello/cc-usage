#!/usr/bin/env swift

import AppKit

// SF Symbol to use - gauge.with.needle.fill looks like a speedometer
let symbolName = "gauge.with.needle.fill"

// Icon sizes needed for macOS app icon
let sizes: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

// Colors
let backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0) // Dark gray like current
let symbolColor = NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1.0) // Orange like current

func createIcon(size: Int) -> NSImage? {
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()

    // Draw rounded rect background
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22 // Standard macOS icon corner radius
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    backgroundColor.setFill()
    path.fill()

    // Get SF Symbol
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.55, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        print("Failed to load symbol: \(symbolName)")
        image.unlockFocus()
        return nil
    }

    // Tint the symbol
    let tintedSymbol = NSImage(size: symbol.size)
    tintedSymbol.lockFocus()
    symbolColor.set()
    let symbolRect = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: symbolRect)
    symbolRect.fill(using: .sourceAtop)
    tintedSymbol.unlockFocus()

    // Center the symbol
    let symbolSize = tintedSymbol.size
    let x = (CGFloat(size) - symbolSize.width) / 2
    let y = (CGFloat(size) - symbolSize.height) / 2
    tintedSymbol.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) -> Bool {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }

    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        return true
    } catch {
        print("Failed to write \(path): \(error)")
        return false
    }
}

// Main
let scriptPath = CommandLine.arguments[0]
let scriptDir = (scriptPath as NSString).deletingLastPathComponent
let projectDir = (scriptDir as NSString).deletingLastPathComponent
let iconsetPath = "\(projectDir)/Resources/AppIcon.iconset"

print("Generating icons with SF Symbol: \(symbolName)")
print("Output directory: \(iconsetPath)")

for (name, size) in sizes {
    if let icon = createIcon(size: size) {
        let path = "\(iconsetPath)/\(name).png"
        if savePNG(icon, to: path) {
            print("  Created \(name).png (\(size)x\(size))")
        }
    }
}

print("\nDone! Now run:")
print("  iconutil -c icns \(iconsetPath) -o \(projectDir)/Resources/AppIcon.icns")
