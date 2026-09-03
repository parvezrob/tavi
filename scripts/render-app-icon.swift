// Renders the app icon (docs/assets/app-icon/direction-a-prompt.svg, owner pick 2026-09-03) as an opaque 1024² PNG:
//   swiftc -O -o /tmp/render-app-icon scripts/render-app-icon.swift && /tmp/render-app-icon apps/ios/Tavi/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers
// Direction A · Prompt, drawn from the same numbers as direction-a-prompt.svg: opaque, 1024², sRGB.
let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1) // SVG coordinates
func rgb(_ hex: UInt32) -> CGColor { CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, 1])! }
ctx.setFillColor(rgb(0x141414)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.setStrokeColor(rgb(0xEBEBEB)); ctx.setLineWidth(112); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 292, y: 318)); ctx.addLine(to: CGPoint(x: 516, y: 512)); ctx.addLine(to: CGPoint(x: 292, y: 706)); ctx.strokePath()
ctx.setFillColor(rgb(0xE8A33D))
ctx.addPath(CGPath(roundedRect: CGRect(x: 588, y: 600, width: 176, height: 108), cornerWidth: 28, cornerHeight: 28, transform: nil)); ctx.fillPath()
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
