import AppKit

let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: canvas).fill()

let tileRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 205, yRadius: 205)

NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
tileShadow.shadowBlurRadius = 38
tileShadow.shadowOffset = NSSize(width: 0, height: -18)
tileShadow.set()
let background = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.035, green: 0.105, blue: 0.18, alpha: 1), 0),
    (NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.53, alpha: 1), 0.58),
    (NSColor(calibratedRed: 0.04, green: 0.61, blue: 0.61, alpha: 1), 1)
)
background?.draw(in: tile, angle: -48)
NSGraphicsContext.restoreGraphicsState()

let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 18, dy: 18), xRadius: 188, yRadius: 188)
rim.lineWidth = 8
NSColor.white.withAlphaComponent(0.14).setStroke()
rim.stroke()

let glow = NSBezierPath(ovalIn: NSRect(x: 585, y: 590, width: 310, height: 310))
NSColor(calibratedRed: 0.2, green: 0.95, blue: 0.75, alpha: 0.10).setFill()
glow.fill()

let shield = NSBezierPath()
shield.move(to: NSPoint(x: 512, y: 805))
shield.curve(to: NSPoint(x: 748, y: 700),
             controlPoint1: NSPoint(x: 595, y: 790),
             controlPoint2: NSPoint(x: 682, y: 755))
shield.curve(to: NSPoint(x: 682, y: 352),
             controlPoint1: NSPoint(x: 748, y: 548),
             controlPoint2: NSPoint(x: 731, y: 430))
shield.curve(to: NSPoint(x: 512, y: 214),
             controlPoint1: NSPoint(x: 635, y: 286),
             controlPoint2: NSPoint(x: 566, y: 236))
shield.curve(to: NSPoint(x: 342, y: 352),
             controlPoint1: NSPoint(x: 458, y: 236),
             controlPoint2: NSPoint(x: 389, y: 286))
shield.curve(to: NSPoint(x: 276, y: 700),
             controlPoint1: NSPoint(x: 293, y: 430),
             controlPoint2: NSPoint(x: 276, y: 548))
shield.curve(to: NSPoint(x: 512, y: 805),
             controlPoint1: NSPoint(x: 342, y: 755),
             controlPoint2: NSPoint(x: 429, y: 790))
shield.close()

NSGraphicsContext.saveGraphicsState()
let shieldShadow = NSShadow()
shieldShadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shieldShadow.shadowBlurRadius = 26
shieldShadow.shadowOffset = NSSize(width: 0, height: -12)
shieldShadow.set()
NSColor.white.withAlphaComponent(0.97).setFill()
shield.fill()
NSGraphicsContext.restoreGraphicsState()

let shackle = NSBezierPath()
shackle.move(to: NSPoint(x: 407, y: 504))
shackle.curve(to: NSPoint(x: 512, y: 626),
              controlPoint1: NSPoint(x: 407, y: 585),
              controlPoint2: NSPoint(x: 456, y: 626))
shackle.curve(to: NSPoint(x: 617, y: 504),
              controlPoint1: NSPoint(x: 568, y: 626),
              controlPoint2: NSPoint(x: 617, y: 585))
shackle.lineWidth = 50
shackle.lineCapStyle = .round
NSColor(calibratedRed: 0.035, green: 0.25, blue: 0.35, alpha: 1).setStroke()
shackle.stroke()

let lockBody = NSBezierPath(roundedRect: NSRect(x: 365, y: 330, width: 294, height: 216),
                            xRadius: 58, yRadius: 58)
let lockGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.03, green: 0.30, blue: 0.40, alpha: 1),
    NSColor(calibratedRed: 0.02, green: 0.16, blue: 0.25, alpha: 1)
])
lockGradient?.draw(in: lockBody, angle: -90)

let keyCircle = NSBezierPath(ovalIn: NSRect(x: 478, y: 412, width: 68, height: 68))
let keyStem = NSBezierPath(roundedRect: NSRect(x: 493, y: 365, width: 38, height: 76),
                           xRadius: 19, yRadius: 19)
NSColor(calibratedRed: 0.20, green: 0.92, blue: 0.66, alpha: 1).setFill()
keyCircle.fill()
keyStem.fill()

image.unlockFocus()

guard CommandLine.arguments.count == 2,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Usage: IconGenerator OUTPUT.png\n", stderr)
    exit(2)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
