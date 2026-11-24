import Foundation

/// The names the app is known by on disk and to macOS. They follow the scheme the owner's
/// other Mac apps share: everything a machine reads is named after the repo, and people read
/// the display name ("GitHub PR Watch", `AppInfo.name` in the UI library).
public enum AppIdentity {
    /// The repo, the executable, the `.app` folder, and the data folder.
    public static let repoName = "github-pr-watch-menubar"
    /// `CFBundleIdentifier`, written by `scripts/bundle.sh`. Also the Keychain service.
    public static let bundleIdentifier = "dev.lubelski.\(repoName)"
    /// The GitHub repository that hosts the source and the releases.
    public static let gitHubRepository = "lubelski/\(repoName)"
    /// The Info.plist key `scripts/bundle.sh` writes the short commit hash into.
    public static let gitCommitKey = "PRWatchGitCommit"
}
