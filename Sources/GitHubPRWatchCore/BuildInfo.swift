import Foundation
import Security

/// Which build this is, read from the bundle. Settings, Debugging shows it and Copy
/// Diagnostics includes it.
public struct BuildInfo: Sendable, Equatable {
    /// `CFBundleShortVersionString`: the latest `v*` tag without the `v`, or the version
    /// `scripts/release.sh` passed.
    public var version: String
    /// `CFBundleVersion`: the commit count, which Sparkle compares.
    public var build: String
    /// The short commit hash, with `-dirty` for a build from uncommitted changes.
    public var commit: String
    public var bundleIdentifier: String
    /// How the bundle is signed, in words.
    public var signing: String
    /// Whether this build has an update feed. Only release builds do.
    public var updates: Bool

    public init(version: String, build: String, commit: String, bundleIdentifier: String, signing: String, updates: Bool) {
        self.version = version
        self.build = build
        self.commit = commit
        self.bundleIdentifier = bundleIdentifier
        self.signing = signing
        self.updates = updates
    }

    /// Reads an Info.plist. Outside a bundle, such as `swift run` or a render, every field
    /// says so instead of guessing.
    public init(info: [String: Any]?, signing: String) {
        let info = info ?? [:]
        self.init(
            version: info["CFBundleShortVersionString"] as? String ?? "development",
            build: info["CFBundleVersion"] as? String ?? "none",
            commit: info[AppIdentity.gitCommitKey] as? String ?? "unknown",
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "none",
            signing: signing,
            updates: AppUpdates.hasFeed(info))
    }

    /// This process's bundle and signature.
    public static func current(bundle: Bundle = .main) -> BuildInfo {
        BuildInfo(info: bundle.infoDictionary, signing: signing(of: bundle.bundleURL))
    }

    /// "0.2.0 (512)".
    public var versionAndBuild: String { "\(version) (\(build))" }

    static func signing(of url: URL) -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return describeSigning(isSigned: false, isAdHoc: false, teamID: nil)
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else {
            return describeSigning(isSigned: false, isAdHoc: false, teamID: nil)
        }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return describeSigning(
            isSigned: dictionary[kSecCodeInfoIdentifier as String] != nil,
            isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    /// How the app is signed, in words.
    public static func describeSigning(isSigned: Bool, isAdHoc: Bool, teamID: String?) -> String {
        if !isSigned { return "Not signed" }
        if isAdHoc { return "Signed ad hoc" }
        if let teamID { return "Signed by team \(teamID)" }
        return "Signed"
    }
}
