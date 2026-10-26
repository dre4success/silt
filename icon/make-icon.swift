// Draws Silt's icon: layers of sediment in the standard macOS rounded square.
// usage: swift icon/make-icon.swift out.png
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: an 824 pt rounded square centred in 1024, corner radius ~185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.28))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0xf4f1ea))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Water above, layers below; each boundary a gentle wave, older layers darker and deeper.
let layers: [(UInt32, CGFloat)] = [(0xcde2fb, 0.70), (0x9ec5f4, 0.59), (0x6da7ec, 0.48), (0x3987e5, 0.38),
                                   (0x256abf, 0.27), (0x184f95, 0.17), (0x0d366b, 0.08)]
ctx.setFillColor(rgb(0xf7f4ee))
ctx.fill(tile)
for (i, (color, top)) in layers.enumerated() {
    let y0 = tile.minY + tile.height * top
    let p = CGMutablePath()
    p.move(to: CGPoint(x: tile.minX, y: tile.minY))
    p.addLine(to: CGPoint(x: tile.minX, y: y0))
    let amp: CGFloat = 16 - CGFloat(i) * 1.2
    let phase = CGFloat(i) * 0.9
    var x = tile.minX
    while x <= tile.maxX + 8 {
        let t = (x - tile.minX) / tile.width
        p.addLine(to: CGPoint(x: x, y: y0 + amp * sin(t * .pi * 2.2 + phase)))
        x += 8
    }
    p.addLine(to: CGPoint(x: tile.maxX, y: tile.minY))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(rgb(color))
    ctx.fillPath()
}

// A few grains settling through the water.
ctx.setFillColor(rgb(0x6da7ec, 0.85))
for (gx, gy, r) in [(0.30, 0.86, 11.0), (0.52, 0.80, 8.0), (0.68, 0.89, 13.0), (0.42, 0.76, 6.0)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.fillEllipse(in: CGRect(x: tile.minX + tile.width * gx - r, y: tile.minY + tile.height * gy - r, width: 2 * r, height: 2 * r))
}
ctx.restoreGState()

// Hairline edge so the light top reads on light backgrounds.
ctx.addPath(squircle)
ctx.setStrokeColor(rgb(0x000000, 0.08))
ctx.setLineWidth(2)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
