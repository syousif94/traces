import AppKit
// Builds the app icons from design/icon-source.png (1024×1024):
//   app/iOS/Assets.xcassets/AppIcon.appiconset  — full bleed, iOS masks the corners
//   app/Mac/Assets.xcassets/AppIcon.appiconset  — macOS shape: inset rounded rect with a shadow, all sizes
//   docs/images/icon.png, docs/images/favicon.png, docs/icon.png
// Usage: swift scripts/make-icons.swift   (from the repo root)
let fm = FileManager.default
let src = NSImage(contentsOfFile: "design/icon-source.png")!

func render(_ size: Int, mac: Bool) -> Data {
    let S = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ctx.interpolationQuality = .high
    if mac {
        // Apple's macOS grid: 824pt body in a 1024 canvas, ~22.5% corner radius, soft drop shadow.
        let inset = S * 100 / 1024
        let rect = NSRect(x: inset, y: inset + S * 0.01, width: S - 2 * inset, height: S - 2 * inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.black.setFill(); path.fill()
        ctx.restoreGState()
        ctx.saveGState(); path.addClip()
        src.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        ctx.restoreGState()
        NSColor.white.withAlphaComponent(0.18).setStroke(); path.lineWidth = max(1, S / 512); path.stroke()
    } else {
        src.draw(in: NSRect(x: 0, y: 0, width: S, height: S), from: .zero, operation: .copy, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    var img = ctx.makeImage()!
    if !mac { // App Store icons must be opaque.
        let o = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        o.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size)); img = o.makeImage()!
    }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
}
func write(_ data: Data, _ path: String) {
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: path))
}
let catalogJSON = #"{ "info" : { "author" : "xcode", "version" : 1 } }"#

// iOS
for cat in ["app/iOS/Assets.xcassets"] {
    write(Data(catalogJSON.utf8), "\(cat)/Contents.json")
    write(render(1024, mac: false), "\(cat)/AppIcon.appiconset/icon-1024.png")
    write(Data(#"""
    { "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
      "info" : { "author" : "xcode", "version" : 1 } }
    """#.utf8), "\(cat)/AppIcon.appiconset/Contents.json")
}
// macOS
let cat = "app/Mac/Assets.xcassets"
write(Data(catalogJSON.utf8), "\(cat)/Contents.json")
var entries: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-\(pt)@\(scale)x.png"
        write(render(pt * scale, mac: true), "\(cat)/AppIcon.appiconset/\(name)")
        entries.append(#"{ "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(pt)x\#(pt)" }"#)
    }
}
write(Data(#"{ "images" : [ \#(entries.joined(separator: ",\n ")) ], "info" : { "author" : "xcode", "version" : 1 } }"#.utf8),
      "\(cat)/AppIcon.appiconset/Contents.json")
// Website / README
write(render(512, mac: true), "docs/images/icon.png")
write(render(64, mac: true), "docs/images/favicon.png")
print("Icons written.")
