import Foundation

/// Reading and writing documents.
public enum TextFile {
    public struct Snapshot: Equatable, Sendable {
        public let text: String
        public let modified: Date?
    }

    public enum Failure: Error, LocalizedError {
        case notText(URL)
        public var errorDescription: String? {
            switch self {
            case .notText(let url): "“\(url.lastPathComponent)” isn’t a text file."
            }
        }
    }

    /// Reads UTF-8 (with or without BOM), falling back to UTF-16 and Latin-1.
    public static func read(_ url: URL) throws -> Snapshot {
        let data = try Data(contentsOf: url)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if data.isEmpty { return Snapshot(text: "", modified: modified) }
        if data.prefix(512).contains(0), !(data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])) {
            throw Failure.notText(url)
        }
        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        if text?.hasPrefix("\u{FEFF}") == true { text?.removeFirst() }
        guard let text else { throw Failure.notText(url) }
        return Snapshot(text: text, modified: modified)
    }

    /// Writes atomically (temp file + rename) so a crash never leaves half a file.
    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> Date? {
        try Data(text.utf8).write(to: url, options: .atomic)
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// A name like "Untitled.md", "Untitled 2.md" that doesn't exist in `folder`.
    public static func availableURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
