import SwiftUI

/// One H1–H3 on the rail.
struct RailHeading: Equatable {
    let level: Int
    let title: String
    /// The start of the section's text, for the hover card.
    let preview: String
    /// UTF-16 offset of the heading line in the document.
    let location: Int
    /// How far into the document the heading sits, 0–100.
    let percent: Int
}

/// The native editor's outline rail, the twin of WebEditor/src/rail.ts: one tick
/// per heading with a faint gradation between, swelling around the pointer
/// (or, at rest, around where you are). Hover shows a card naming the
/// section; press jumps there, dragging scrubs.
struct OutlineRailView: View {
    let headings: [RailHeading]
    /// The heading being read, when the pointer isn't on the rail.
    let current: Int
    let jump: (_ heading: Int, _ animated: Bool) -> Void

    @State private var hover: Int?
    @State private var dragging = false

    private static let width: CGFloat = 52
    private static let sigma = 1.15
    private static let grow: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let shown = Self.sample(headings.count, toFit: geo.size.height)
            let rows = shown.count * 2 - 1
            let pitch = min(11, max(6, geo.size.height * 0.7 / CGFloat(rows)))
            let top = (geo.size.height - pitch * CGFloat(rows)) / 2

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        tick(row, shown).frame(height: pitch)
                    }
                }
                .padding(.leading, 14)
                .frame(width: Self.width, alignment: .leading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hover = row(at: point.y, pitch: pitch, rows: rows)
                    case .ended: if !dragging { hover = nil }
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let row = row(at: value.location.y, pitch: pitch, rows: rows)
                    hover = row
                    jump(shown[row / 2], !dragging)
                    dragging = true
                }.onEnded { _ in dragging = false })
                .offset(y: top)

                if let hover {
                    card(headings[shown[min(hover / 2, shown.count - 1)]])
                        .position(x: Self.width + 4 + 130,
                                  y: min(max(top + (CGFloat(hover) + 0.5) * pitch, 70), geo.size.height - 70))
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(x: -6)))
                }
            }
            .animation(.easeOut(duration: 0.16), value: hover == nil)
        }
        .frame(width: Self.width + 280)
    }

    /// Indices of the headings to draw: all of them, or an even sample when
    /// they wouldn't fit at the tightest pitch (so the rail is never cut off).
    private static func sample(_ count: Int, toFit height: CGFloat) -> [Int] {
        let capacity = max(3, Int((height * 0.9 / 6 + 1) / 2))
        guard count > capacity else { return Array(0..<count) }
        return (0..<capacity).map { $0 * count / capacity }
    }

    private func row(at y: CGFloat, pitch: CGFloat, rows: Int) -> Int {
        max(0, min(rows - 1, Int(y / pitch)))
    }

    private func tick(_ row: Int, _ shown: [Int]) -> some View {
        let minor = row % 2 == 1
        let level = headings[shown[row / 2]].level
        // At rest: the last drawn heading at or before the one being read.
        let here = shown.lastIndex { $0 <= current } ?? 0
        let centre = Double(hover ?? here * 2)
        let distance = (Double(row) - centre) / 2
        let weight = exp(-(distance * distance) / (2 * Self.sigma * Self.sigma))
        let base: CGFloat = minor ? 4 : 8 + CGFloat(max(0, 3 - level)) * 3
        let rest = minor ? 0.14 : 0.3 + Double(max(0, 3 - level)) * 0.07
        let active = !minor && Double(row) == centre
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.primary)
            .frame(width: base + CGFloat(weight) * (minor ? 8 : Self.grow), height: active ? 3 : 2)
            .opacity(rest + weight * (1 - rest))
            .animation(dragging ? .linear(duration: 0.09) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.26), value: centre)
    }

    private func card(_ heading: RailHeading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(heading.percent)% IN")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(.tertiary)
            Text(heading.title.isEmpty ? "Untitled" : heading.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            if !heading.preview.isEmpty {
                Text(heading.preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .lineSpacing(2)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Chrome.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }
}
