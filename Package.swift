// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Native TextKit 2 live-Markdown editor, used when Settings › Editor is "Native".
        // Vendored from nodes-app/swift-markdown-engine 0.15.0 with a small patch
        // (rendered code blocks, for Mermaid); see Vendor/README.md.
        .package(path: "Vendor/swift-markdown-engine"),
        // Mermaid diagrams drawn natively (no web view) for the native editor.
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", from: "1.0.0"),
    ],
    targets: [
        // Pure logic (file tree, open routing, tab titles, fuzzy match, file I/O). No UI; unit tested.
        .target(name: "MarginCore", path: "Sources/MarginCore"),
        // The AppKit app. The editor page is prebuilt from Editor/ into Resources/Editor.
        .executableTarget(
            name: "Margin",
            dependencies: [
                "MarginCore",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineCodeBlocks", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineLatex", package: "swift-markdown-engine"),
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
            ],
            path: "Sources/Margin",
            resources: [.copy("Resources/Editor")],
            // SwiftPM records the deployment target as the SDK version, which makes
            // macOS draw the app in compatibility mode (no Liquid Glass). Record the
            // real SDK so AppKit uses the current design; still runs on macOS 14.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos",
                                           "-Xlinker", "14.0", "-Xlinker", "26.0"])]
        ),
        .testTarget(name: "MarginCoreTests", dependencies: ["MarginCore"], path: "Tests/MarginCoreTests"),
    ]
)
