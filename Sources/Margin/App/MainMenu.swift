import AppKit

/// The menu bar, built in code. Items with a nil target travel the responder
/// chain to the key window's WorkspaceWindowController (or the AppDelegate).
@MainActor
enum MainMenu {
    static func build(recentDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu(recentDelegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("Markdown Syntax", #selector(AppDelegate.showHelp(_:))))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "Margin")
        m.addItem(item("About Margin", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        m.addItem(submenu(services, title: "Services"))
        m.addItem(.separator())
        m.addItem(item("Hide Margin", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("Quit Margin", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu(_ recentDelegate: NSMenuDelegate) -> NSMenu {
        let m = NSMenu(title: "File")
        m.addItem(item("New File", #selector(WorkspaceWindowController.newDocument(_:)), "n"))
        m.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = recentDelegate
        m.addItem(submenu(recent, title: "Open Recent"))
        m.addItem(item("Go to File…", #selector(WorkspaceWindowController.quickOpen(_:)), "p"))
        m.addItem(.separator())
        m.addItem(item("Close Tab", #selector(WorkspaceWindowController.closeTab(_:) as (WorkspaceWindowController) -> (Any?) -> Void), "w"))
        m.addItem(item("Close Window", #selector(WorkspaceWindowController.closeWindow(_:)), "w", [.command, .shift]))
        m.addItem(item("Save", #selector(WorkspaceWindowController.saveDocument(_:)), "s"))
        m.addItem(item("Save As…", #selector(WorkspaceWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        m.addItem(.separator())
        let export = NSMenu(title: "Export")
        export.addItem(item("HTML…", #selector(WorkspaceWindowController.exportHTML(_:))))
        export.addItem(item("PDF…", #selector(WorkspaceWindowController.exportPDF(_:))))
        m.addItem(submenu(export, title: "Export"))
        m.addItem(item("Print…", #selector(WorkspaceWindowController.printDocument(_:)), "p", [.command, .option]))
        m.addItem(.separator())
        m.addItem(item("Reveal in Finder", #selector(WorkspaceWindowController.revealInFinder(_:)), "r", [.command, .shift]))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(item("Undo", Selector(("undo:")), "z"))
        m.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        m.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        m.addItem(item("Delete", #selector(NSText.delete(_:))))
        m.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        m.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(WorkspaceWindowController.showFind(_:)), "f"))
        find.addItem(item("Find and Replace…", #selector(WorkspaceWindowController.showFindAndReplace(_:)), "f", [.command, .option]))
        find.addItem(item("Find Next", #selector(WorkspaceWindowController.findNextMatch(_:)), "g"))
        find.addItem(item("Find Previous", #selector(WorkspaceWindowController.findPreviousMatch(_:)), "g", [.command, .shift]))
        find.addItem(.separator())
        find.addItem(item("Search in Folder…", #selector(WorkspaceWindowController.searchInFolder(_:)), "f", [.command, .shift]))
        m.addItem(submenu(find, title: "Find"))
        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        m.addItem(submenu(spelling, title: "Spelling and Grammar"))
        return m
    }

    private static func formatMenu() -> NSMenu {
        let m = NSMenu(title: "Format")
        let style = NSMenu(title: "Text Style")
        style.addItem(format("Body", "heading0", "0", [.command, .option]))
        for level in 1...6 {
            style.addItem(format("Heading \(level)", "heading\(level)", "\(level)", [.command, .option]))
        }
        m.addItem(submenu(style, title: "Text Style"))
        m.addItem(.separator())
        m.addItem(format("Bold", "bold", "b"))
        m.addItem(format("Italic", "italic", "i"))
        m.addItem(format("Strikethrough", "strike", "x", [.command, .shift]))
        m.addItem(format("Inline Code", "code", "e"))
        m.addItem(format("Highlight", "highlight", "e", [.command, .shift]))
        m.addItem(format("Link…", "link", "k"))
        m.addItem(.separator())
        m.addItem(format("Bulleted List", "bulletList", "8", [.command, .shift]))
        m.addItem(format("Numbered List", "orderedList", "7", [.command, .shift]))
        m.addItem(format("Task List", "taskList", "9", [.command, .shift]))
        m.addItem(format("Quote", "blockquote", "b", [.command, .shift]))
        m.addItem(.separator())
        let insert = NSMenu(title: "Insert")
        insert.addItem(format("Code Block", "codeBlock", "c", [.command, .option]))
        insert.addItem(format("Inline Formula…", "inlineMath", "e", [.command, .option]))
        insert.addItem(format("Block Formula…", "blockMath", "e", [.command, .option, .shift]))
        insert.addItem(format("Table", "table", "t", [.command, .option]))
        insert.addItem(format("Image…", "image", "i", [.command, .shift]))
        insert.addItem(format("Diagram (Mermaid)", "mermaid"))
        insert.addItem(format("Divider", "horizontalRule"))
        m.addItem(submenu(insert, title: "Insert"))
        let table = NSMenu(title: "Table")
        for (title, command) in EditorWebView.tableCommands {
            table.addItem(title.isEmpty ? .separator() : format(title, command))
        }
        m.addItem(submenu(table, title: "Table"))
        m.addItem(.separator())
        m.addItem(format("Clear Formatting", "clearFormatting", "\\", [.command]))
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        m.addItem(item("Hide Sidebar", #selector(WorkspaceWindowController.toggleSidebarVisibility(_:)), "s", [.command, .control]))
        m.addItem(item("Focus Mode", #selector(WorkspaceWindowController.toggleFocusMode(_:)), "\r", [.command, .shift]))
        m.addItem(item("Markdown Source", #selector(WorkspaceWindowController.toggleSourceMode(_:)), "m", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Bigger Text", #selector(AppDelegate.zoomIn(_:)), "+"))
        m.addItem(item("Smaller Text", #selector(AppDelegate.zoomOut(_:)), "-"))
        m.addItem(item("Actual Size", #selector(AppDelegate.actualSize(_:)), "0"))
        m.addItem(.separator())
        m.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item("Show Next Tab", #selector(WorkspaceWindowController.selectNextTab(_:)), "]", [.command, .shift]))
        m.addItem(item("Show Previous Tab", #selector(WorkspaceWindowController.selectPreviousTab(_:)), "[", [.command, .shift]))
        let next = item("Show Next Tab", #selector(WorkspaceWindowController.selectNextTab(_:)), "\t", [.control])
        next.isAlternate = false
        next.isHidden = true
        next.allowsKeyEquivalentWhenHidden = true
        m.addItem(next)
        let prev = item("Show Previous Tab", #selector(WorkspaceWindowController.selectPreviousTab(_:)), "\t", [.control, .shift])
        prev.isHidden = true
        prev.allowsKeyEquivalentWhenHidden = true
        m.addItem(prev)
        let go = NSMenu(title: "Go to Tab")
        for n in 1...9 {
            let i = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(WorkspaceWindowController.selectTabByNumber(_:)), "\(n)")
            i.tag = n
            go.addItem(i)
        }
        m.addItem(submenu(go, title: "Go to Tab"))
        m.addItem(.separator())
        m.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }

    // MARK: Helpers

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return i
    }

    private static func format(_ title: String, _ command: String, _ key: String = "",
                               _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = item(title, #selector(WorkspaceWindowController.formatCommand(_:)), key, modifiers)
        i.representedObject = command
        return i
    }

    private static func submenu(_ menu: NSMenu, title: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title ?? menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }
}
