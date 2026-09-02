import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-icon.swift OUTPUT_PNG\n".utf8))
    exit(2)
}

let canvasSize = NSSize(width: 1_024, height: 1_024)
let image = NSImage(size: canvasSize)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let tile = NSBezierPath(
    roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
    xRadius: 206,
    yRadius: 206
)
let background = NSGradient(
    starting: NSColor(red: 0.055, green: 0.15, blue: 0.24, alpha: 1),
    ending: NSColor(red: 0.025, green: 0.62, blue: 0.48, alpha: 1)
)!
background.draw(in: tile, angle: -52)

let highlight = NSBezierPath(
    roundedRect: NSRect(x: 104, y: 104, width: 816, height: 816),
    xRadius: 174,
    yRadius: 174
)
NSColor.white.withAlphaComponent(0.055).setStroke()
highlight.lineWidth = 4
highlight.stroke()

let center = NSPoint(x: 500, y: 540)
let ringRadius: CGFloat = 268
let inactiveRing = NSBezierPath()
inactiveRing.appendArc(
    withCenter: center,
    radius: ringRadius,
    startAngle: 42,
    endAngle: 318,
    clockwise: false
)
inactiveRing.lineWidth = 92
inactiveRing.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.22).setStroke()
inactiveRing.stroke()

let activeRing = NSBezierPath()
activeRing.appendArc(
    withCenter: center,
    radius: ringRadius,
    startAngle: 42,
    endAngle: 258,
    clockwise: false
)
activeRing.lineWidth = 92
activeRing.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.96).setStroke()
activeRing.stroke()

let tail = NSBezierPath()
tail.move(to: NSPoint(x: 656, y: 374))
tail.line(to: NSPoint(x: 780, y: 246))
tail.lineWidth = 92
tail.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.96).setStroke()
tail.stroke()

let barData: [(x: CGFloat, height: CGFloat, alpha: CGFloat)] = [
    (372, 132, 0.55),
    (476, 210, 0.76),
    (580, 292, 0.96)
]
for bar in barData {
    let path = NSBezierPath(
        roundedRect: NSRect(x: bar.x, y: 398, width: 62, height: bar.height),
        xRadius: 31,
        yRadius: 31
    )
    NSColor.white.withAlphaComponent(bar.alpha).setFill()
    path.fill()
}

image.unlockFocus()

guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("Could not render Quota icon.\n".utf8))
    exit(3)
}

try pngData.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
