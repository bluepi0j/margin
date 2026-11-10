import AppKit
import XCTest
@testable import Margin

@MainActor
final class DiagramViewerTests: XCTestCase {
    /// Twenty-four steps in a row: far wider than a text column.
    private let wide = "graph LR\n" + (1..<24).map { "  N\($0)[Step number \($0)] --> N\($0 + 1)[Step number \($0 + 1)]" }.joined(separator: "\n")

    func testShowsADiagramWholeAndZooms() throws {
        _ = NSApplication.shared
        let viewer = DiagramViewer.shared
        viewer.show(code: wide, name: "notes diagram", directory: nil, from: nil)
        defer { viewer.window?.close() }
        XCTAssertEqual(viewer.window?.isVisible, true)
        XCTAssertFalse(viewer.canvas.isHidden)
        let size = viewer.canvas.frame.size
        XCTAssertGreaterThan(size.width, 2000)
        // Opens with all of it in view.
        let visible = viewer.scrollView.contentSize
        let fit = viewer.scrollView.magnification
        XCTAssertEqual(fit, min(visible.width / size.width, visible.height / size.height, 2), accuracy: 0.001)
        viewer.zoomIn(nil)
        XCTAssertEqual(viewer.scrollView.magnification, fit * 1.25, accuracy: 0.001)
        viewer.actualSize(nil)
        XCTAssertEqual(viewer.scrollView.magnification, 1, accuracy: 0.001)
        viewer.zoomToFit(nil)
        XCTAssertEqual(viewer.scrollView.magnification, fit, accuracy: 0.001)
    }

    func testThePNGIsTheDiagramAtTwiceItsSize() throws {
        _ = NSApplication.shared
        let viewer = DiagramViewer.shared
        viewer.show(code: "graph TD\n  A[Idea] --> B[Draft]\n  B --> C{Good?}", name: "x", directory: nil, from: nil)
        defer { viewer.window?.close() }
        let png = try XCTUnwrap(viewer.canvas.pngData())
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        let size = viewer.canvas.frame.size
        XCTAssertEqual(image.pixelsWide, Int((size.width * 2).rounded(.up)))
        XCTAssertEqual(image.pixelsHigh, Int((size.height * 2).rounded(.up)))
        // On the page's background, not see-through: it will be pasted elsewhere.
        XCTAssertEqual(image.colorAt(x: 2, y: 2)?.alphaComponent, 1)
    }

    func testSourceThatCannotBeDrawnSaysSo() {
        _ = NSApplication.shared
        let viewer = DiagramViewer.shared
        viewer.show(code: "this is not a diagram", name: "x", directory: nil, from: nil)
        defer { viewer.window?.close() }
        XCTAssertTrue(viewer.canvas.isHidden)
        XCTAssertNil(viewer.canvas.pngData())
    }
}
