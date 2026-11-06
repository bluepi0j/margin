import Foundation

/// The committed version of a file, for showing what changed since the last
/// commit. Reads through the `git` command line tool; never writes to the
/// repository (no index refresh, no locks).
public enum GitBaseline {
    public enum Result: Equatable, Sendable {
        /// The file as of HEAD ("" for a file that is new since then).
        case committed(String)
        /// Not inside a git working tree, or git isn't installed.
        case unavailable
    }

    /// The working tree that holds `file`, by looking for `.git` in the
    /// folders above it. Cheap; no process is started.
    public static func repositoryRoot(for file: URL) -> URL? {
        var dir = file.resolvingSymlinksInPath().deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            // ("/" minus its last component is "/..", not "/".)
            if dir.path == "/" || dir.path.isEmpty { return nil }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// The text of `file` at HEAD. Runs `git`; call it off the main thread.
    public static func headText(for file: URL) -> Result {
        guard repositoryRoot(for: file) != nil, let git = gitExecutable() else { return .unavailable }
        let resolved = file.resolvingSymlinksInPath()
        let dir = resolved.deletingLastPathComponent()
        // `./name` is relative to -C, so no need to know the repository root.
        // --filters applies the checkout conversions (line endings, LFS smudge)
        // so the text compares like the file on disk.
        let spec = "HEAD:./" + resolved.lastPathComponent
        if let data = run(git, ["-C", dir.path, "cat-file", "--filters", spec]) {
            return .committed(TextFile.decode(data) ?? "")
        }
        // Not in HEAD: a new file, or a repository without commits yet.
        guard let inside = run(git, ["-C", dir.path, "rev-parse", "--is-inside-work-tree"]),
              String(decoding: inside, as: UTF8.self).hasPrefix("true") else { return .unavailable }
        return .committed("")
    }

    /// A git that runs without prompting. `/usr/bin/git` is only a stub that
    /// offers to install the developer tools when they are missing.
    static func gitExecutable() -> URL? { cachedGit }
    private static let cachedGit: URL? = findGit()
    private static func findGit() -> URL? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git",
                          "/Library/Developer/CommandLineTools/usr/bin/git"]
        if let developer = run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"]) {
            let path = String(decoding: developer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { candidates.append(path + "/usr/bin/git") }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Standard output of a successful run, or nil.
    private static func run(_ executable: URL, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"     // never take index.lock while an agent is committing
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
