import AppKit

// Draws the lumac app icon from scratch: a slate-blue gradient squircle with a
// clean white crescent (a nod to "lu"/luna, and to the app's ring motif).
//
//   swift Tools/makelumac.swift <out.png>

let out = CommandLine.arguments.count >= 2
    ? CommandLine.arguments[1]
    : "Sources/lumac/Resources/appicon.png"

let size = 1024.0
let inset = 100.0                       // macOS art sits in an 824pt plate
let plateSize = size - inset * 2
let corner = 228.0

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let canvas = NSImage(size: NSSize(width: size, height: size))
canvas.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Plate with a top-lit slate-blue gradient (light at top, deep at bottom).
let plate = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: plateSize, height: plateSize),
    xRadius: corner, yRadius: corner)
NSGradient(starting: rgb(0x2b3644), ending: rgb(0x5d7288))!
    .draw(in: plate, angle: 90)

// A soft highlight in the upper area for a little depth.
ctx.saveGState()
plate.addClip()
let glow = NSGradient(colors: [rgb(0xffffff).withAlphaComponent(0.14), rgb(0xffffff).withAlphaComponent(0)])!
glow.draw(fromCenter: NSPoint(x: 512, y: 720), radius: 0,
          toCenter: NSPoint(x: 512, y: 720), radius: 520, options: [])
ctx.restoreGState()

// Crescent = outer disc MINUS an equal offset disc. Even-odd would leave both
// lunes (an "eye"), so this subtracts properly by clipping: to the plate, then
// to the outer disc, then to everything *outside* the cut disc. A slight tilt
// gives it a little life.
ctx.saveGState()
plate.addClip()
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: -12 * .pi / 180)
ctx.translateBy(x: -512, y: -512)

let r = 272.0
let offset = 150.0
let cx = 560.0
NSBezierPath(ovalIn: NSRect(x: cx - r, y: 512 - r, width: 2 * r, height: 2 * r)).addClip()

// rect XOR cut-disc = everything outside the cut disc; intersecting the clips
// above leaves just the crescent.
let cut = NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size))
cut.appendOval(in: NSRect(x: cx + offset - r, y: 512 - r, width: 2 * r, height: 2 * r))
cut.windingRule = .evenOdd
cut.addClip()

rgb(0xf4f6f8).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
ctx.restoreGState()

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("render failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
