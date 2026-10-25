import AppKit

// Entry point. A plain AppKit app: no storyboard, no SwiftUI App scene, so
// window/tab management stays fully under our control.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
