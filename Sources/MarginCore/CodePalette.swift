/// Syntax-highlighting colors, shared by both editors so a code block looks the
/// same in Web and Native. The web editor's copy is the `--hl-*` and
/// `--code-bg` variables in WebEditor/src/styles.css; `CodePaletteTests` fails if
/// the two drift apart.
public enum CodePalette {
    /// What a token is, as far as color goes.
    public enum Role: String, CaseIterable, Sendable {
        case keyword, string, number, comment, function, type, attr
    }

    public struct Colors: Sendable {
        /// 0xRRGGBB per role.
        public let roles: [Role: Int]
        /// Code that no role colors.
        public let text: Int
        public let background: Int
    }

    /// GitHub (Primer) light.
    public static let light = Colors(
        roles: [.keyword: 0xCF222E, .string: 0x0A3069, .number: 0x0550AE, .comment: 0x6E7781,
                .function: 0x8250DF, .type: 0x953800, .attr: 0x116329],
        text: 0x24292F,
        background: 0xF6F7F9
    )

    /// GitHub (Primer) dark.
    public static let dark = Colors(
        roles: [.keyword: 0xFF7B72, .string: 0xA5D6FF, .number: 0x79C0FF, .comment: 0x8B949E,
                .function: 0xD2A8FF, .type: 0xFFA657, .attr: 0x7EE787],
        text: 0xE6EDF3,
        background: 0x262628
    )

    /// highlight.js scope names per role — the same grouping as the `.hljs-*`
    /// rules in styles.css. A dotted scope without an entry falls back to its
    /// parent (`title.function.invoke` → `title.function` → `title`).
    public static let scopes: [Role: [String]] = [
        .keyword: ["keyword", "selector-tag", "built_in", "doctag", "template-tag", "deletion"],
        .string: ["string", "regexp", "char.escape"],
        .number: ["number", "literal", "symbol", "bullet", "variable.constant"],
        .comment: ["comment", "quote", "meta"],
        .function: ["title", "title.function", "section"],
        .type: ["type", "title.class", "params"],
        .attr: ["attr", "attribute", "name", "selector-class", "selector-id", "tag", "addition"],
    ]
}
