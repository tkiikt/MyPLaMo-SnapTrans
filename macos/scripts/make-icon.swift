// Renders assets/icon/app.svg (F design) into an .iconset: swift scripts/make-icon.swift <app.svg> <out.iconset>
import AppKit
let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOfFile: args[1]) else { print("usage: make-icon.swift <svg> <iconset>"); exit(1) }
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // macOS icon grid: the artwork sits in ~80 % of the canvas (824/1024) so it matches other app icons.
        let inset = Double(px) * (100.0 / 1024.0)
        svg.draw(in: NSRect(x: inset, y: inset, width: Double(px) - 2 * inset, height: Double(px) - 2 * inset))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
