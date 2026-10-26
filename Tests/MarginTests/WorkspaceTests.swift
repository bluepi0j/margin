import AppKit
import SwiftUI
import XCTest
@testable import Margin
import MarginCore

@MainActor
final class WorkspaceTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("margin-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLeavingNewFileDoesNotSaveWhenAutosaveIsOff() async throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.autosave
        Preferences.shared.autosave = false
        defer { Preferences.shared.autosave = previous }
        let folder = try temporaryFolder()
        let editor = TestEditor()
        let controller = WorkspaceWindowController(folder: folder, editor: editor)
        controller.newUntitled()
        let tab = try XCTUnwrap(controller.workspace.activeTab)
        let originalURL = try XCTUnwrap(tab.url)
        editor.edits[tab.id] = "# Keep in memory\n"
        await controller.flushEditor()
        controller.newUntitled()
        XCTAssertEqual(tab.url, originalURL)
        XCTAssertEqual(try TextFile.read(originalURL).text, "")
        XCTAssertEqual(tab.unsavedText, "# Keep in memory\n")
    }

    func testAutosaveDoesNotOverwriteAnExternalEditBeforeWatcherRuns() async throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.autosave
        Preferences.shared.autosave = true
        defer { Preferences.shared.autosave = previous }
        let file = try temporaryFolder().appendingPathComponent("note.md")
        try TextFile.write("original", to: file)
        let editor = TestEditor()
        let controller = WorkspaceWindowController(folder: nil, editor: editor)
        controller.openFile(file)
        let tab = try XCTUnwrap(controller.workspace.activeTab)
        try TextFile.write("external edit", to: file)
        editor.edits[tab.id] = "my edit"
        await controller.flushEditor()
        XCTAssertEqual(try TextFile.read(file).text, "external edit")
        XCTAssertEqual(tab.unsavedText, "my edit")
        XCTAssertTrue(tab.hasConflict)
        // Explicit Save is the existing "Keep Mine" action.
        let saved = await controller.save(tab)
        XCTAssertTrue(saved)
        XCTAssertEqual(try TextFile.read(file).text, "my edit")
    }

    func testPendingNewFileIsNamedAfterBackgroundContentArrives() async throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.autosave
        Preferences.shared.autosave = true
        defer { Preferences.shared.autosave = previous }
        let editor = TestEditor()
        let controller = WorkspaceWindowController(folder: try temporaryFolder(), editor: editor)
        controller.newUntitled()
        let first = try XCTUnwrap(controller.workspace.activeTab)
        editor.onEvent?(.edited(id: first.id))
        controller.newUntitled()
        editor.onEvent?(.content(id: first.id, markdown: "# Posted after switching\n"))
        let file = try XCTUnwrap(first.url)
        XCTAssertEqual(file.lastPathComponent, "Posted after switching.md")
        XCTAssertEqual(try TextFile.read(file).text, "# Posted after switching\n")
        XCTAssertFalse(first.isDirty)
    }

    func testQuittingStopsWhenDraftCannotBeSaved() async throws {
        _ = NSApplication.shared
        let previousFolder = Drafts.folder
        let previousAutosave = Preferences.shared.autosave
        Drafts.folder = try temporaryFolder()
        Preferences.shared.autosave = false
        defer {
            Drafts.folder = previousFolder
            Preferences.shared.autosave = previousAutosave
        }
        let editor = TestEditor()
        let controller = WorkspaceWindowController(folder: nil, editor: editor)
        controller.newUntitled()
        let tab = try XCTUnwrap(controller.workspace.activeTab)
        let file = try XCTUnwrap(tab.url)
        // A directory at the destination forces a real filesystem write failure.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        editor.edits[tab.id] = "unsaved draft"
        let canClose = await controller.prepareToClose(quitting: true)
        XCTAssertFalse(canClose)
        XCTAssertEqual(tab.unsavedText, "unsaved draft")
        XCTAssertNotNil(tab.saveError)
    }

    func testUnreportedEditsPreventCloseAndSave() async throws {
        _ = NSApplication.shared
        let file = try temporaryFolder().appendingPathComponent("note.md")
        try TextFile.write("original", to: file)
        let controller = WorkspaceWindowController(folder: nil, editor: TestEditor())
        controller.openFile(file)
        let tab = try XCTUnwrap(controller.workspace.activeTab)
        tab.isEditing = true // The editor couldn't return its pending text.
        let canClose = await controller.closeTab(tab.id)
        let canQuit = await controller.prepareToClose(quitting: true)
        let saved = await controller.save(tab)
        XCTAssertFalse(canClose)
        XCTAssertFalse(canQuit)
        XCTAssertFalse(saved)
        XCTAssertEqual(controller.workspace.tabs.count, 1)
        XCTAssertEqual(try TextFile.read(file).text, "original")
    }

    func testQuitSessionUsesAutoRenamedPath() async throws {
        _ = NSApplication.shared
        let previous = Preferences.shared.autosave
        Preferences.shared.autosave = true
        defer { Preferences.shared.autosave = previous }
        let editor = TestEditor()
        let controller = WorkspaceWindowController(folder: try temporaryFolder(), editor: editor)
        controller.newUntitled()
        let tab = try XCTUnwrap(controller.workspace.activeTab)
        editor.edits[tab.id] = "# Final title\n"
        let canQuit = await controller.prepareToClose(quitting: true)
        XCTAssertTrue(canQuit)
        let path = try XCTUnwrap(controller.sessionState.activeFile)
        XCTAssertTrue(path.hasSuffix("/Final title.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(controller.sessionState.files, [path])
    }
}

@MainActor
private final class TestEditor: DocumentEditor {
    var onEvent: ((EditorEvent) -> Void)?
    var savePastedImage: ((NSPasteboard) -> String?)?
    var edits: [String: String] = [:]
    var view: AnyView { AnyView(EmptyView()) }
    var focusView: NSView? { nil }
    func open(id: String, markdown: String, documentURL: URL?, activate: Bool) {}
    func activate(id: String) {}
    func close(id: String) {}
    func reload(id: String, markdown: String) {}
    func moved(id: String, documentURL: URL?) {}
    func command(_ name: String, args: [String: Any]) {}
    func flush() async -> [String: String] { defer { edits = [:] }; return edits }
    func setSourceMode(_ on: Bool) {}
    func find(_ mode: String) {}
    func applySettings() {}
    func focus() {}
    func goToHeading(_ index: Int) {}
    func reveal(_ text: String) {}
}
