import AppKit

// Run from the project root: swift Scripts/generate-icons.swift
_ = NSApplication.shared
let resources = URL(fileURLWithPath: "Sources/FolderFlow/Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("FolderFlow.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
guard let icon = NSImage(contentsOf: resources.appendingPathComponent("app_icon.png")) else {
    fatalError("The original FolderFlow logo is unavailable.")
}

func png(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let edge = CGFloat(size)
    let scale = min(edge / icon.size.width, edge / icon.size.height)
    let width = icon.size.width * scale, height = icon.size.height * scale
    icon.draw(in: NSRect(x: (edge - width) / 2, y: (edge - height) / 2, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    precondition(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0, "Icon background must remain transparent.")
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(size: size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("FolderFlow.icns").path]
try process.run()
process.waitUntilExit()
precondition(process.terminationStatus == 0, "ICNS generation failed.")
print("Generated ICNS sizes from the unchanged original FolderFlow logo.")
