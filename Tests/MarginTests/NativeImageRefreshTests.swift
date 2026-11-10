import AppKit
import MarkdownEngine
import SwiftUI
import XCTest
@testable import Margin

@MainActor
final class NativeImageRefreshTests: XCTestCase {
    private func png(_ width: Int, _ height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testAnImageWrittenAgainIsReadAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margin-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pic.png")
        try png(10, 10).write(to: file)
        let images = LocalImageProvider()
        images.base = folder
        let request = EmbeddedImageRequest(name: "pic.png")
        XCTAssertEqual(images.image(for: request)?.size, NSSize(width: 10, height: 10))
        let fingerprint = images.fingerprint()
        XCTAssertFalse(images.dropChanged())

        try png(30, 20).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        XCTAssertTrue(images.dropChanged())
        XCTAssertNotEqual(images.fingerprint(), fingerprint)
        XCTAssertEqual(images.image(for: request)?.size, NSSize(width: 30, height: 20))
        XCTAssertFalse(images.dropChanged())

        // Without being told: the next request notices by itself.
        try png(5, 5).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: file.path)
        XCTAssertEqual(images.image(for: request)?.size, NSSize(width: 5, height: 5))
    }

    func testComingBackToTheAppDrawsARewrittenImage() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("margin-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pic.png")
        try png(10, 10).write(to: file)

        let editor = NativeDocumentEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: editor.view)
        window.contentView = host
        defer { window.close() }
        editor.open(id: "image-test", markdown: "Before\n\n![pic](pic.png)\n\nAfter\n",
                    documentURL: folder.appendingPathComponent("doc.md"), activate: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let tv = try XCTUnwrap(editor.focusView as? NSTextView)
        XCTAssertEqual(imageSizes(tv), [NSSize(width: 10, height: 10)])

        try png(30, 20).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(imageSizes(tv), [NSSize(width: 30, height: 20)])
    }

    /// Sizes of the images the text carries in its attributes.
    private func imageSizes(_ tv: NSTextView) -> [NSSize] {
        var sizes: [NSSize] = []
        guard let storage = tv.textStorage else { return sizes }
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, _, _ in
            for value in attrs.values {
                let image = value as? NSImage ?? (value as? NSTextAttachment)?.image
                if let image, !sizes.contains(image.size) { sizes.append(image.size) }
            }
        }
        return sizes
    }
}
