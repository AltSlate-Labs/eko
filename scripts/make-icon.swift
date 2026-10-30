// Renders the Eko app icon (red record dot on a dark rounded square) as PNG at the given size.
// usage: swift make-icon.swift <size> <output.png>
import AppKit

let size = CGFloat(Double(CommandLine.arguments[1])!)
let output = CommandLine.arguments[2]
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.04, dy: size * 0.04)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
path.fill()
// waveform bars
let barColor = NSColor(calibratedWhite: 0.92, alpha: 1)
let heights: [CGFloat] = [0.22, 0.42, 0.62, 0.42, 0.22]
let barWidth = size * 0.055
let gap = size * 0.045
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2 - size * 0.12
for h in heights {
    let barHeight = size * h
    let bar = NSBezierPath(roundedRect: CGRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight), xRadius: barWidth / 2, yRadius: barWidth / 2)
    barColor.setFill()
    bar.fill()
    x += barWidth + gap
}
// red record dot
let dotSize = size * 0.26
let dot = CGRect(x: size * 0.64, y: size * 0.37, width: dotSize, height: dotSize)
NSColor(calibratedRed: 0.95, green: 0.27, blue: 0.22, alpha: 1).setFill()
NSBezierPath(ovalIn: dot).fill()
NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
NSBezierPath(ovalIn: dot.insetBy(dx: dotSize * 0.3, dy: dotSize * 0.3)).fill()
_ = ctx
image.unlockFocus()
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
rep.size = NSSize(width: size, height: size)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: output))
