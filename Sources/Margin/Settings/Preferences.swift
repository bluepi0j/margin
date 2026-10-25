import AppKit
import Observation

/// User settings, persisted in UserDefaults. Windows observe changes through
/// `Preferences.didChange`.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("MarginPreferencesDidChange")

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { ["system": "System", "light": "Light", "dark": "Dark"][rawValue]! }
    }

    /// Typeface of the document text.
    enum FontStyle: String, CaseIterable, Identifiable {
        case sans, serif, mono
        var id: String { rawValue }
        var title: String { ["sans": "Sans", "serif": "Serif", "mono": "Mono"][rawValue]! }

        /// PostScript name for the native editor.
        var fontName: String {
            let base = NSFont.systemFont(ofSize: 16)
            switch self {
            case .sans: return base.fontName
            case .serif: return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 16) }?.fontName ?? base.fontName
            case .mono: return NSFont.monospacedSystemFont(ofSize: 16, weight: .regular).fontName
            }
        }
    }

    enum EditorEngine: String, CaseIterable, Identifiable {
        case web, native
        var id: String { rawValue }
    }

    var appearance: Appearance { didSet { save("appearance", appearance.rawValue) } }
    var editorEngine: EditorEngine { didSet { save("editorEngine", editorEngine.rawValue) } }
    var fontSize: Double { didSet { save("fontSize", fontSize) } }
    var fontStyle: FontStyle { didSet { save("fontStyle", fontStyle.rawValue) } }
    var contentWidth: Double { didSet { save("contentWidth", contentWidth) } }
    var autosave: Bool { didSet { save("autosave", autosave) } }
    var showAllFiles: Bool { didSet { save("showAllFiles", showAllFiles) } }
    var restoreSession: Bool { didSet { save("restoreSession", restoreSession) } }
    /// The column of heading ticks beside the text.
    var showOutlineRail: Bool { didSet { save("showOutlineRail", showOutlineRail) } }

    static let fontSizes: ClosedRange<Double> = 12...26

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "appearance": Appearance.system.rawValue, "fontSize": 16.0, "contentWidth": 760.0,
            "autosave": true, "showAllFiles": false, "restoreSession": true, "showOutlineRail": true, "editorEngine": EditorEngine.web.rawValue,
        ])
        editorEngine = EditorEngine(rawValue: d.string(forKey: "editorEngine") ?? "") ?? .web
        fontStyle = FontStyle(rawValue: d.string(forKey: "fontStyle") ?? "") ?? .sans
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        fontSize = d.double(forKey: "fontSize")
        contentWidth = d.double(forKey: "contentWidth")
        autosave = d.bool(forKey: "autosave")
        showAllFiles = d.bool(forKey: "showAllFiles")
        restoreSession = d.bool(forKey: "restoreSession")
        showOutlineRail = d.bool(forKey: "showOutlineRail")
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        applyAppearance()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Settings forwarded to every editor page.
    var editorSettings: [String: Any] {
        ["fontSize": fontSize, "width": contentWidth, "font": fontStyle.rawValue, "accent": Self.controlAccentHex,
         "rail": showOutlineRail]
    }

    /// The system accent color (links, caret, selection in the editor page),
    /// so the page matches whatever the user picked in System Settings.
    static var controlAccentHex: String {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            ?? NSColor.systemBlue.usingColorSpace(.sRGB)!
        return String(format: "#%02x%02x%02x",
                      Int(round(color.redComponent * 255)),
                      Int(round(color.greenComponent * 255)),
                      Int(round(color.blueComponent * 255)))
    }

    func zoom(by delta: Double) {
        fontSize = min(Self.fontSizes.upperBound, max(Self.fontSizes.lowerBound, fontSize + delta))
    }
}
