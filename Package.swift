// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "GitHubPRWatch",
    platforms: [.macOS(.v27)],
    targets: [
        // Models, GitHub client, auth, classifier, filters, transitions, and PRStore. No UI.
        .target(name: "GitHubPRWatchCore"),
        // Every SwiftUI view and the notification center glue. A library so the render
        // tool can draw the same views without launching the app.
        .target(name: "GitHubPRWatchUI", dependencies: ["GitHubPRWatchCore"]),
        // The app itself: only the `App` scene definition.
        .executableTarget(name: "GitHubPRWatch", dependencies: ["GitHubPRWatchCore", "GitHubPRWatchUI"]),
        // Windowless renders of the UI with placeholder data. See AGENTS.md.
        .executableTarget(name: "GitHubPRWatchRender", dependencies: ["GitHubPRWatchCore", "GitHubPRWatchUI"]),
        .testTarget(name: "GitHubPRWatchCoreTests", dependencies: ["GitHubPRWatchCore"]),
    ]
)
