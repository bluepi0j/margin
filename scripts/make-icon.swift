// Turns Resources/AppIcon.svg (drawn by scripts/icon/cat.cjs) into
// Resources/AppIcon.icns: renders it once with WebKit, then scales it down to
// every icon size.
// Run: swift scripts/make-icon.swift   (from the Markdown/ folder)
import AppKit
import WebKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("Resources/AppIcon.svg")
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let master: CGFloat = 1024

func write(_ master: NSBitmapImageRep) {
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            context.imageInterpolation = .high
            NSGraphicsContext.current = context
            master.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy,
                        fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
        }
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try! iconutil.run()
    iconutil.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    print(iconutil.terminationStatus == 0 ? "wrote \(icns.path)" : "iconutil failed")
    exit(iconutil.terminationStatus)
}

/// Loads the SVG in a web view and snapshots it at `master` pixels.
final class Renderer: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let scale = NSScreen.main?.backingScaleFactor ?? 2

    override init() {
        let points = master / scale
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: points, height: points))
        view.setValue(false, forKey: "drawsBackground")
        super.init()
        view.navigationDelegate = self
        let svg = try! String(contentsOf: svgURL, encoding: .utf8)
            .replacingOccurrences(of: "<svg ", with: "<svg width='100%' height='100%' ", options: [], range: nil)
        view.loadHTMLString("<html><body style='margin:0;background:transparent'><div style='width:\(points)px;height:\(points)px'>\(svg)</div></body></html>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Filters settle a frame after load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: Double(master / self.scale))
            webView.takeSnapshot(with: config) { image, _ in
                guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                    print("snapshot failed"); exit(1)
                }
                write(rep)
            }
        }
    }
}

let app = NSApplication.shared
let renderer = Renderer()
app.run()
