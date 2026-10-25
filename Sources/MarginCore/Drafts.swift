import Foundation

/// New files that don't belong to a folder yet. They are real files in the
/// app's support folder, saved on every change like any other document, so
/// nothing is ever lost and no save dialog is needed to start writing.
public enum Drafts {
    public static var folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Margin/Drafts", isDirectory: true)
    }()

    public static func isDraft(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.deletingLastPathComponent().canonicalPath == folder.canonicalPath
    }

    /// Creates an empty draft file and returns its URL.
    public static func create() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Draft-\(UUID().uuidString.prefix(8)).md")
        try TextFile.write("", to: url)
        return url
    }
}

public enum DocumentTitle {
    /// A file-name-safe title from the first line of a document:
    /// "# My Plan" -> "My Plan". nil when there is no usable text.
    public static func from(markdown: String, maxLength: Int = 60) -> String? {
        var body = markdown
        // Skip YAML front matter.
        if body.hasPrefix("---\n"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) {
            body = String(body[end.upperBound...])
        }
        guard let line = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        var title = line
        // Strip block markers and inline formatting characters.
        title = title.replacingOccurrences(of: #"^([-*+] \[[ xX]\]|#{1,6}|>|[-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[*_`~=$<>\\]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[/:|?"]"#, with: "-", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ".-")))
        if title.count > maxLength { title = String(title.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return title.isEmpty ? nil : title
    }
}
