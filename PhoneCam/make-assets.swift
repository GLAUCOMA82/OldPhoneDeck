// Draws the launch image (plain black, 640x960) and a 120x120 home-screen icon.
import AppKit

func png(_ w: Int, _ h: Int, _ path: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
png(640, 960, out + "/Default@2x.png") { $0.setFillColor(.black); $0.fill(CGRect(x: 0, y: 0, width: 640, height: 960)) }
png(120, 120, out + "/Icon-60@2x.png") { c in
    c.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
    c.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1))
    c.fill(CGRect(x: 18, y: 34, width: 84, height: 56))                       // screen
    c.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1))
    c.fillEllipse(in: CGRect(x: 44, y: 46, width: 32, height: 32))            // lens
    c.setFillColor(.white); c.fillEllipse(in: CGRect(x: 52, y: 54, width: 16, height: 16))
}
