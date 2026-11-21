// Saves the icon macOS shows for an app, as Finder and the Dock would draw it.
//
//   swiftc scripts/render-icon.swift -o /tmp/render-icon && /tmp/render-icon "dist/MPC Loader.app" out.png
//
// Exits with an error when macOS falls back to its generic app icon, which means the app's own
// icon was not found.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: render-icon <app> <output.png>")
    exit(2)
}
let app = arguments[1]
let output = URL(fileURLWithPath: arguments[2])
let side = 512

func pixels(_ image: NSImage) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let icon = NSWorkspace.shared.icon(forFile: app)
let generic = NSWorkspace.shared.icon(for: .application)
guard let drawn = pixels(icon), let fallback = pixels(generic) else {
    print("render-icon: could not draw the icon")
    exit(1)
}
try drawn.write(to: output)
if drawn == fallback {
    print("render-icon: macOS shows the generic app icon, so the app's own icon was not found")
    exit(1)
}
print("render-icon: saved \(output.path)")
