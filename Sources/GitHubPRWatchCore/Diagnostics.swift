import Foundation

/// What Settings, Debugging shows, and what Copy Diagnostics puts on the clipboard.
///
/// Everything in it is a count, a date, a state, or a path. It never holds a token, the
/// signed-in login, the watched repos, or a pull request, so the copied text can be pasted
/// into an issue. A failed poll's error message is GitHub's own text, as the app shows it.
public struct DiagnosticsReport: Sendable, Equatable {
    public var date: Date
    public var build: BuildInfo
    public var system: String
    /// The data folder, with the home folder written as `~`.
    public var dataFolder: String

    public var signedIn: Bool
    public var authMethod: AuthMethod?
    public var cliInstalled: Bool
    public var teamAccess: PRStore.TeamAccess

    public var watchedRepos: Int
    public var failedRepos: Int
    public var views: Int
    public var pullRequests: Int

    public var pollInterval: TimeInterval
    public var polling: Bool
    public var lastPollStarted: Date?
    public var lastUpdated: Date?
    public var connection: PRStore.ConnectionState
    public var rateLimit: RateLimit?

    /// The `title` of each experiment that is on.
    public var experimentsOn: [String]

    public init(
        date: Date, build: BuildInfo, system: String, dataFolder: String, signedIn: Bool, authMethod: AuthMethod?,
        cliInstalled: Bool, teamAccess: PRStore.TeamAccess, watchedRepos: Int, failedRepos: Int, views: Int,
        pullRequests: Int, pollInterval: TimeInterval, polling: Bool, lastPollStarted: Date?, lastUpdated: Date?,
        connection: PRStore.ConnectionState, rateLimit: RateLimit?, experimentsOn: [String]
    ) {
        self.date = date
        self.build = build
        self.system = system
        self.dataFolder = dataFolder
        self.signedIn = signedIn
        self.authMethod = authMethod
        self.cliInstalled = cliInstalled
        self.teamAccess = teamAccess
        self.watchedRepos = watchedRepos
        self.failedRepos = failedRepos
        self.views = views
        self.pullRequests = pullRequests
        self.pollInterval = pollInterval
        self.polling = polling
        self.lastPollStarted = lastPollStarted
        self.lastUpdated = lastUpdated
        self.connection = connection
        self.rateLimit = rateLimit
        self.experimentsOn = experimentsOn
    }

    /// A report of the store as it is now.
    @MainActor
    public init(
        store: PRStore, build: BuildInfo, date: Date = Date(),
        system: String = ProcessInfo.processInfo.operatingSystemVersionString,
        dataFolder: URL = JSONFileStore<AppConfig>.applicationSupportDirectory,
        home: String = NSHomeDirectory(), defaults: UserDefaults = .standard
    ) {
        self.init(
            date: date, build: build, system: system,
            dataFolder: Self.abbreviate(dataFolder.path, home: home),
            signedIn: store.viewer != nil, authMethod: store.authMethod, cliInstalled: store.isCLIInstalled,
            teamAccess: store.teamAccess, watchedRepos: store.watchedRepos.count, failedRepos: store.failedRepos.count,
            views: store.views.count, pullRequests: store.pullRequests.count, pollInterval: store.pollInterval,
            polling: store.isRefreshing, lastPollStarted: store.lastPollStarted, lastUpdated: store.lastUpdated,
            connection: store.connection, rateLimit: store.rateLimit,
            experimentsOn: Experiment.enabled(defaults).map(\.title))
    }

    // MARK: Wording, shared by the Debugging section and the copied text

    public static func describe(_ method: AuthMethod?) -> String {
        switch method {
        case .githubCLI: "GitHub CLI login (token read from gh each time, not stored)"
        case .deviceFlow: "Sign in with GitHub (token in the Keychain)"
        case .pastedToken: "Pasted token (in the Keychain)"
        case nil: "None"
        }
    }

    public static func describe(_ connection: PRStore.ConnectionState) -> String {
        switch connection {
        case .idle: "No poll has finished yet"
        case .upToDate: "Worked"
        case .offline: "Offline"
        case .rateLimited: "Rate limit ran out"
        case .secondaryRateLimited: "Secondary rate limit, slowing down"
        case .tokenRejected: "Sign-in rejected"
        case .failed(let text): "Failed: \(text)"
        }
    }

    public static func describe(_ access: PRStore.TeamAccess) -> String {
        switch access {
        case .unknown: "Not checked yet"
        case .available: "Readable"
        case .missingScope: "Missing read:org, so only requests by name count"
        case .failed(let text): "Failed: \(text)"
        }
    }

    public static func describe(_ limit: RateLimit?) -> String {
        guard let limit else { return "Not known yet" }
        return "\(limit.remaining) of \(limit.limit) points left, resets \(timestamp(limit.resetAt))"
    }

    /// A path with the home folder written as `~`, so the copied text doesn't carry the
    /// account name.
    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(.iso8601)
    }

    /// The text Copy Diagnostics puts on the clipboard.
    public func plainText() -> String {
        var lines = [
            "GitHub PR Watch diagnostics, \(Self.timestamp(date))",
            "",
            "Version: \(build.versionAndBuild)",
            "Commit: \(build.commit)",
            "Bundle identifier: \(build.bundleIdentifier)",
            "Signing: \(build.signing)",
            "Updates: \(build.updates ? "From the latest GitHub Release" : "None, not a release build")",
            "System: \(system)",
            "Data folder: \(dataFolder)",
            "",
            "Signed in: \(signedIn ? "Yes" : "No")",
            "Sign-in method: \(Self.describe(authMethod))",
            "GitHub CLI found: \(cliInstalled ? "Yes" : "No")",
            "Team review requests: \(Self.describe(teamAccess))",
            "",
            "Watched repos: \(watchedRepos)\(failedRepos > 0 ? ", \(failedRepos) not readable" : "")",
            "Views: \(views)",
            "Open pull requests: \(pullRequests)",
            "",
            "Poll every: \(Int(pollInterval)) seconds",
            "Polling now: \(polling ? "Yes" : "No")",
            "Last poll started: \(Self.timestamp(lastPollStarted))",
            "Last poll result: \(Self.describe(connection))",
            "Last successful poll: \(Self.timestamp(lastUpdated))",
            "Rate limit: \(Self.describe(rateLimit))",
            "",
        ]
        lines.append("Experiments on: " + (experimentsOn.isEmpty ? "None" : experimentsOn.joined(separator: ", ")))
        return lines.joined(separator: "\n") + "\n"
    }
}
