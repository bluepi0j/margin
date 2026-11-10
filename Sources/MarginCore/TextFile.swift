import Foundation

/// Reading and writing documents.
public enum TextFile {
    public struct Snapshot: Equatable, Sendable {
        public let text: String
        public let modified: Date?
        /// How the file's bytes spell the text, so a save writes them the same way.
        public let encoding: String.Encoding
    }

    public enum Failure: Error, LocalizedError {
        case notText(URL)
        case notEncodable(URL)
        public var errorDescription: String? {
            switch self {
            case .notText(let url): "“\(url.lastPathComponent)” isn’t a text file."
            case .notEncodable(let url): "“\(url.lastPathComponent)” isn’t UTF-8, and its encoding can’t hold some of these characters. Save As makes a UTF-8 copy."
            }
        }
    }

    /// Reads UTF-8 (with or without BOM), falling back to UTF-16 and Latin-1.
    public static func read(_ url: URL) throws -> Snapshot {
        let data = try Data(contentsOf: url)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let (text, encoding) = decoded(data) else { throw Failure.notText(url) }
        return Snapshot(text: text, modified: modified, encoding: encoding)
    }

    /// File bytes as text, the way `read` decodes them; nil for binary data.
    public static func decode(_ data: Data) -> String? { decoded(data)?.text }

    private static func decoded(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.isEmpty { return ("", .utf8) }
        // The byte order is kept apart, to write the same one back.
        let utf16: String.Encoding? = data.starts(with: [0xFF, 0xFE]) ? .utf16LittleEndian
            : data.starts(with: [0xFE, 0xFF]) ? .utf16BigEndian : nil
        if data.prefix(512).contains(0), utf16 == nil { return nil }
        var text: String
        let encoding: String.Encoding
        if let utf8 = String(data: data, encoding: .utf8) {
            (text, encoding) = (utf8, .utf8)
        } else if let utf16, let wide = String(data: data, encoding: .utf16) {
            (text, encoding) = (wide, utf16)
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            (text, encoding) = (latin1, .isoLatin1)
        } else {
            return nil
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return (text, encoding)
    }

    /// Writes atomically (temp file + rename) so a crash never leaves half a file.
    ///
    /// `encoding` is the one the file was read in. A file that isn't UTF-8
    /// keeps its bytes that way: rewriting text read as Latin-1 (the fallback
    /// for GBK, Shift-JIS…) as UTF-8 would replace every byte above ASCII.
    /// Throws when the text has characters that encoding can't hold.
    @discardableResult
    public static func write(_ text: String, to url: URL, encoding: String.Encoding = .utf8) throws -> Date? {
        // Atomic replacement of a symlink replaces the link itself. Save to
        // its target so editing a linked document preserves both locations.
        let destination = url.resolvingSymlinksInPath()
        var data: Data
        if encoding == .utf8 {
            data = Data(text.utf8)
        } else {
            guard let encoded = text.data(using: encoding) else { throw Failure.notEncodable(url) }
            data = encoded
            if encoding == .utf16LittleEndian { data.insert(contentsOf: [0xFF, 0xFE], at: 0) }
            if encoding == .utf16BigEndian { data.insert(contentsOf: [0xFE, 0xFF], at: 0) }
        }
        try data.write(to: destination, options: .atomic)
        return try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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
