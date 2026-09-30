#!/usr/bin/env swift
// Renders the Spacious app icon into Spacious/Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Spacious/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle-ish background with a blue → indigo gradient (macOS icon grid: ~10% margin).
    let inset = s * 0.1
    let bg = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: bg.width * 0.225, yRadius: bg.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 0.36, green: 0.25, blue: 0.85, alpha: 1))!
        .draw(in: bgPath, angle: -90)

    // A monitor split into zones: one tall zone on the left, two stacked on the right.
    let pad = bg.width * 0.14
    let area = bg.insetBy(dx: pad, dy: pad)
    let gap = bg.width * 0.045
    let r = bg.width * 0.05
    let leftW = (area.width - gap) * 0.58
    let rightW = area.width - gap - leftW
    let halfH = (area.height - gap) / 2
    let zones: [(NSRect, CGFloat)] = [
        (NSRect(x: area.minX, y: area.minY, width: leftW, height: area.height), 0.95),
        (NSRect(x: area.minX + leftW + gap, y: area.minY + halfH + gap, width: rightW, height: halfH), 0.75),
        (NSRect(x: area.minX + leftW + gap, y: area.minY, width: rightW, height: halfH), 0.55),
    ]
    for (rect, alpha) in zones {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(size: px).write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconset.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(iconset.path)")
