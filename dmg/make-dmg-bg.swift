// DMG background: the canvas IS a dark faux-Safari window. Toolbar with
// traffic lights, an address pill "browsing" the Chrome Web Store, and a
// glowing puzzle piece sitting in Safari's extension area — the product story
// (Chrome extensions, native in Safari) told by the chrome itself.
// Ghost arch watermark sits behind the drag path: app crosses the viaduct
// to /Applications. Output: dmg/dmg-bg.png at 2x (620x420 points).
// Dark-only by choice: macOS 27 Finder does NOT live-swap a multi-rep DMG
// background by appearance, so a single dark bg is the honest call.
// One-shot asset gen, run by make-dmg.sh.
import AppKit

let W = 620.0, H = 420.0
let MINT = NSColor(calibratedRed: 0.42, green: 0.78, blue: 0.76, alpha: 1)
let INK  = NSColor(calibratedRed: 0.62, green: 0.67, blue: 0.72, alpha: 1)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*2), pixelsHigh: Int(H*2),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let c = ctx.cgContext

// ---- helpers -------------------------------------------------------------
func symbol(_ name: String, _ size: Double, _ weight: NSFont.Weight, _ color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    // tint opaque — low-alpha fill leaves the black template bleeding through;
    // callers dim via the `fraction:` of draw() instead
    return NSImage(size: img.size, flipped: false) { r in
        img.draw(in: r); color.withAlphaComponent(1).set(); r.fill(using: .sourceAtop); return true
    }
}

// ---- window body: dark teal-slate vertical gradient ----------------------
let bodyTop = NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.17, alpha: 1)
let bodyBot = NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.12, alpha: 1)
NSGradient(starting: bodyBot, ending: bodyTop)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

// soft radial mint glow behind the drag path (center of content area)
let glow = NSGradient(colors: [MINT.withAlphaComponent(0.10), .clear])!
glow.draw(fromCenter: NSPoint(x: W/2, y: 195), radius: 0,
          toCenter: NSPoint(x: W/2, y: 195), radius: 230, options: [])

// ---- ghost arch watermark: the viaduct the app "crosses" -----------------
if let arch = NSImage(contentsOfFile: "icon.png") {
    let s = 250.0
    arch.draw(in: NSRect(x: W/2 - s/2, y: 185 - s/2, width: s, height: s),
              from: .zero, operation: .sourceOver, fraction: 0.06)
}

// ---- toolbar strip (faux Safari chrome) -----------------------------------
let TB = 52.0                                  // toolbar height, top of canvas
NSColor(white: 1, alpha: 0.045).setFill()
NSBezierPath(rect: NSRect(x: 0, y: H - TB, width: W, height: TB)).fill()
NSColor(white: 1, alpha: 0.08).setFill()       // hairline under toolbar
NSBezierPath(rect: NSRect(x: 0, y: H - TB - 1, width: W, height: 1)).fill()

// traffic lights
let lights: [NSColor] = [
    NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
    NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
for (i, col) in lights.enumerated() {
    col.withAlphaComponent(0.9).setFill()
    NSBezierPath(ovalIn: NSRect(x: 20 + Double(i)*20, y: H - TB/2 - 6, width: 12, height: 12)).fill()
}

// back/forward chevrons in a grouped pill (real Safari style)
let navGroup = NSRect(x: 92, y: H - TB + 12, width: 62, height: 28)
NSColor(white: 1, alpha: 0.06).setFill()
NSBezierPath(roundedRect: navGroup, xRadius: 14, yRadius: 14).fill()
for (i, name) in ["chevron.left", "chevron.right"].enumerated() {
    let img = symbol(name, 12, .semibold, INK)
    let cx = navGroup.midX + (i == 0 ? -13.0 : 13.0)   // symmetric around pill center
    img.draw(at: NSPoint(x: cx - img.size.width/2, y: navGroup.midY - img.size.height/2),
             from: .zero, operation: .sourceOver, fraction: i == 0 ? 0.8 : 0.35)
}

// address pill, centered — Safari browsing the Chrome Web Store.
// Page glyph left, URL centered, reload right (real Safari layout).
let pill = NSRect(x: 180, y: H - TB + 12, width: 280, height: 28)
NSColor(white: 1, alpha: 0.07).setFill()
NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14).fill()
let page = symbol("macwindow", 11, .medium, INK)
page.draw(at: NSPoint(x: pill.minX + 10, y: pill.midY - page.size.height/2), from: .zero, operation: .sourceOver, fraction: 0.6)
let reload = symbol("arrow.clockwise", 11, .medium, INK)
reload.draw(at: NSPoint(x: pill.maxX - 10 - reload.size.width, y: pill.midY - reload.size.height/2), from: .zero, operation: .sourceOver, fraction: 0.6)
let urlFont = NSFont.systemFont(ofSize: 12, weight: .regular)
let url = NSAttributedString(string: "chromewebstore.google.com",
    attributes: [.font: urlFont, .foregroundColor: INK.withAlphaComponent(0.85)])
url.draw(at: NSPoint(x: pill.midX - url.size().width/2, y: pill.midY - url.size().height/2))

// right cluster: new tab + tab overview in their own pill
let tabGroup = NSRect(x: W - 20 - 62, y: H - TB + 12, width: 62, height: 28)
NSColor(white: 1, alpha: 0.06).setFill()
NSBezierPath(roundedRect: tabGroup, xRadius: 14, yRadius: 14).fill()
for (i, name) in ["plus", "square.on.square"].enumerated() {
    let img = symbol(name, 13, .medium, INK)
    let cx = tabGroup.midX + (i == 0 ? -13.0 : 13.0)
    img.draw(at: NSPoint(x: cx - img.size.width/2, y: tabGroup.midY - img.size.height/2),
             from: .zero, operation: .sourceOver, fraction: 0.55)
}

// ---- headline: two-tone, centered ----------------------------------------
let hl = NSFont.systemFont(ofSize: 25, weight: .bold)
let h1 = NSAttributedString(string: "Your Chrome extensions, ",
    attributes: [.font: hl, .foregroundColor: NSColor(white: 0.92, alpha: 0.92)])
let h2 = NSAttributedString(string: "in your browser.",
    attributes: [.font: hl, .foregroundColor: MINT])
let hw = h1.size().width + h2.size().width
let hx = (W - hw)/2, hy = H - TB - 62
h1.draw(at: NSPoint(x: hx, y: hy))
h2.draw(at: NSPoint(x: hx + h1.size().width, y: hy))

// ---- drag path: arrow through the arch ------------------------------------
// Finder icons (96px) sit at {150,240} and {470,240} in top-origin coords ->
// centers at y=180 bottom-origin. Arrow spans the gap between them.
let ay = 180.0
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 252, y: ay))
arrow.line(to: NSPoint(x: 350, y: ay))
arrow.lineWidth = 9
arrow.lineCapStyle = .round
MINT.setStroke()
arrow.stroke()
let head = NSBezierPath()   // stroke + fill with round joins = chunky rounded tip
head.move(to: NSPoint(x: 370, y: ay))
head.line(to: NSPoint(x: 348, y: ay + 13))
head.line(to: NSPoint(x: 348, y: ay - 13))
head.close()
head.lineWidth = 7
head.lineJoinStyle = .round
MINT.setFill()
MINT.setStroke()
head.fill()
head.stroke()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "dmg/dmg-bg.png"))
print("wrote dmg/dmg-bg.png")
