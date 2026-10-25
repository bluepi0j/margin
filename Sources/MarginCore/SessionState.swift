import Foundation

/// What gets saved on quit and restored on launch.
public struct SessionState: Codable, Equatable {
    public struct Window: Codable, Equatable {
        public var folder: String?
        public var files: [String]
        public var activeFile: String?
        public var sidebarVisible: Bool
        public var frame: String?
        public var expandedFolders: [String]

        public init(folder: String?, files: [String], activeFile: String?, sidebarVisible: Bool, frame: String?, expandedFolders: [String] = []) {
            self.folder = folder
            self.files = files
            self.activeFile = activeFile
            self.sidebarVisible = sidebarVisible
            self.frame = frame
            self.expandedFolders = expandedFolders
        }
    }

    public var windows: [Window]

    public init(windows: [Window]) {
        self.windows = windows
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data?) -> SessionState? {
        data.flatMap { try? JSONDecoder().decode(SessionState.self, from: $0) }
    }

    /// Drops files and folders that no longer exist, and windows left with nothing.
    public func pruned(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> SessionState {
        SessionState(windows: windows.compactMap { w in
            var w = w
            if let f = w.folder, !fileExists(f) { w.folder = nil }
            w.files = w.files.filter(fileExists)
            if let a = w.activeFile, !w.files.contains(a) { w.activeFile = w.files.first }
            return (w.folder == nil && w.files.isEmpty) ? nil : w
        })
    }
}
