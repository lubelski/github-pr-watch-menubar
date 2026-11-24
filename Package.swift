// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "github-pr-watch-menubar",
    platforms: [.macOS(.v27)],
    dependencies: [
        // The updater. Only the app target links it, and only `AppUpdater.swift` imports it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Models, GitHub client, auth, classifier, filters, transitions, and PRStore. No UI.
        .target(name: "GitHubPRWatchCore"),
        // Every SwiftUI view and the notification center glue. A library so the render
        // tool can draw the same views without launching the app.
        .target(name: "GitHubPRWatchUI", dependencies: ["GitHubPRWatchCore"]),
        // The app itself: the `App` scene definition and the updater. Named after the repo,
        // as the executable inside the bundle is.
        .executableTarget(
            name: "github-pr-watch-menubar",
            dependencies: ["GitHubPRWatchCore", "GitHubPRWatchUI", .product(name: "Sparkle", package: "Sparkle")]
        ),
        // Windowless renders of the UI with placeholder data. See AGENTS.md.
        .executableTarget(name: "GitHubPRWatchRender", dependencies: ["GitHubPRWatchCore", "GitHubPRWatchUI"]),
        .testTarget(name: "GitHubPRWatchCoreTests", dependencies: ["GitHubPRWatchCore"]),
    ]
)
