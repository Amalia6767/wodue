import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    let bg = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
    NSColor(srgbRed: 0.70, green: 0.37, blue: 0.44, alpha: 1).setFill()
    bg.fill()
    NSColor(srgbRed: 1, green: 0.98, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 236, y: 223, width: 552, height: 578), xRadius: 55, yRadius: 55).fill()
    NSColor(srgbRed: 0.91, green: 0.84, blue: 0.82, alpha: 1).setStroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 304, y: 659)); line.line(to: NSPoint(x: 720, y: 659))
    line.lineWidth = 18; line.lineCapStyle = .round; line.stroke()
    NSColor(srgbRed: 0.70, green: 0.37, blue: 0.44, alpha: 1).setStroke()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 350, y: 460)); check.line(to: NSPoint(x: 465, y: 350)); check.line(to: NSPoint(x: 675, y: 555))
    check.lineWidth = 49; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(size).png"))
}

func appendSize(_ size: Int, to data: inout Data) {
    var value = UInt32(size).bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
var chunks = Data()
for (size, kind) in [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
    let png = try Data(contentsOf: out.appendingPathComponent("\(size).png"))
    chunks.append(Data(kind.utf8))
    appendSize(png.count + 8, to: &chunks)
    chunks.append(png)
}
var icon = Data("icns".utf8)
appendSize(chunks.count + 8, to: &icon)
icon.append(chunks)
try icon.write(to: out.appendingPathComponent("AppIcon.icns"))
