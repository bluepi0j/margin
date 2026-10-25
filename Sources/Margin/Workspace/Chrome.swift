import AppKit
import SwiftUI

/// Colors and metrics shared by the window chrome. Margin draws its own
/// header, sidebar and format bar (no system toolbar), so they live here.
enum Chrome {
    /// Height of the top row; the traffic lights sit centered in it.
    static let headerHeight: CGFloat = 52
    /// Room the traffic lights take at the window's left edge.
    static let trafficLightsWidth: CGFloat = 78

    static let sidebar = Color(nsColor: NSColor(name: "MarginSidebar") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.135, alpha: 1)
            : NSColor(red: 0.969, green: 0.969, blue: 0.965, alpha: 1)
    })
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
    static let hover = Color.primary.opacity(0.045)
    static let selected = Color.primary.opacity(0.075)
}

/// Empty chrome you can drag the window by (and double-click to zoom), like a
/// title bar. Put it behind header rows.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.miniaturize(nil) } else if action != "None" { window?.zoom(nil) }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// A borderless icon (or short text) button that lights up on hover — the
/// one button style used across the chrome. Its name shows in a small label
/// right away, instead of after the system tooltip's long delay.
struct ChromeButton: View {
    var symbol: String?
    var text: String?
    let help: String
    var active = false
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false
    @State private var showsTip = false
    @Environment(\.isEnabled) private var isEnabled

    init(symbol: String, help: String, active: Bool = false, size: CGFloat = 28, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.active = active
        self.size = size
        self.action = action
    }

    init(text: String, help: String, active: Bool = false, size: CGFloat = 28, action: @escaping () -> Void) {
        self.text = text
        self.help = help
        self.active = active
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13.5, weight: .regular))
                } else {
                    Text(text ?? "").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Chrome.selected : (hovering && isEnabled ? Chrome.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard hovering else { showsTip = false; return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { showsTip = true } }
        }
        .simultaneousGesture(TapGesture().onEnded { showsTip = false })
        .overlay(alignment: .top) {
            if showsTip {
                Text(help)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Chrome.hairline, lineWidth: 1))
                    .offset(y: size + 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
