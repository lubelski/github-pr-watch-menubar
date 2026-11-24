import Foundation
import Observation

/// Everything `PRStore` talks to. `live()` for the app; `inMemory(api:)` for tests and renders.
public struct PRStoreDependencies: Sendable {
    /// Whether the GitHub CLI is installed.
    public var cliInstalled: @Sendable () -> Bool
    /// Reads the GitHub CLI's token on demand.
    public var cliTokens: any TokenProvider
    /// Device-flow and pasted tokens.
    public var secrets: any SecretStore
    /// Builds a GitHub client that asks `tokens` for its token.
    public var makeAPI: @Sendable (any TokenProvider) -> any GitHubAPI
    /// `nil` hides the device-flow path (no OAuth client ID yet).
    public var deviceFlow: DeviceFlow?
    public var config: any DocumentStore<AppConfig>
    public var views: any DocumentStore<[SavedView]>
    public var snapshot: any DocumentStore<TransitionSnapshot>
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        cliInstalled: @escaping @Sendable () -> Bool,
        cliTokens: any TokenProvider,
        secrets: any SecretStore,
        makeAPI: @escaping @Sendable (any TokenProvider) -> any GitHubAPI,
        deviceFlow: DeviceFlow?,
        config: any DocumentStore<AppConfig>,
        views: any DocumentStore<[SavedView]>,
        snapshot: any DocumentStore<TransitionSnapshot>,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.cliInstalled = cliInstalled
        self.cliTokens = cliTokens
        self.secrets = secrets
        self.makeAPI = makeAPI
        self.deviceFlow = deviceFlow
        self.config = config
        self.views = views
        self.snapshot = snapshot
        self.now = now
        self.sleep = sleep
    }

    /// The real thing: `gh`, the Keychain, GitHub, and JSON files in Application Support.
    public static func live() -> PRStoreDependencies {
        let cli = GitHubCLI()
        return PRStoreDependencies(
            cliInstalled: { GitHubCLI.locate() != nil },
            cliTokens: cli,
            secrets: KeychainSecrets(),
            makeAPI: { GitHubClient(tokens: $0) },
            deviceFlow: OAuthConfig.isDeviceFlowAvailable ? DeviceFlow() : nil,
            config: JSONFileStore<AppConfig>(applicationSupportFile: "config.json"),
            views: JSONFileStore<[SavedView]>(applicationSupportFile: "views.json"),
            snapshot: JSONFileStore<TransitionSnapshot>(applicationSupportFile: "snapshot.json")
        )
    }

    /// No disk, no Keychain, no network. `api` answers every GitHub call.
    public static func inMemory(
        api: any GitHubAPI, cliInstalled: Bool = true, config: AppConfig? = nil, views: [SavedView]? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> PRStoreDependencies {
        PRStoreDependencies(
            cliInstalled: { cliInstalled },
            cliTokens: StaticTokenProvider("placeholder-token"),
            secrets: InMemorySecrets(),
            makeAPI: { _ in api },
            deviceFlow: nil,
            config: InMemoryDocumentStore(config),
            views: InMemoryDocumentStore(views),
            snapshot: InMemoryDocumentStore<TransitionSnapshot>(),
            now: now,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
    }
}

/// The app model: auth, watched repos, views, the open PRs with their status, and polling.
/// Every view reads from here. Built with `PRStoreDependencies`, so it runs on fakes.
@MainActor
@Observable
public final class PRStore {
    public enum AuthState: Equatable, Sendable {
        case signedOut
        /// Checking a token with GitHub.
        case signingIn(AuthMethod)
        /// The device flow is waiting for the user to enter `code.userCode` on github.com.
        case awaitingDeviceApproval(DeviceCode)
        case signedIn(Viewer, AuthMethod)
    }

    public enum ConnectionState: Equatable, Sendable {
        /// No poll has finished yet.
        case idle
        case upToDate
        case offline
        case rateLimited(until: Date?)
        case secondaryRateLimited(until: Date?)
        /// GitHub returned 401, or `gh` has no login. Polling stops until the user acts.
        case tokenRejected
        case failed(String)

        public var message: String? {
            switch self {
            case .idle, .upToDate: nil
            case .offline: "Offline. Retrying."
            case .rateLimited(let until): "GitHub's rate limit ran out" + (until.map { ". Resumes at \($0.formatted(date: .omitted, time: .shortened))" } ?? "") + "."
            case .secondaryRateLimited: "GitHub asked us to slow down. Retrying shortly."
            case .tokenRejected: "GitHub rejected the sign-in. Sign in again."
            case .failed(let text): text
            }
        }
    }

    /// Whether "review requested from my teams" can work.
    public enum TeamAccess: Equatable, Sendable {
        /// Not asked yet.
        case unknown
        /// The token reads team membership.
        case available
        /// The token lacks `read:org` (or the Members permission). Only requests by name count.
        case missingScope
        /// The last attempt failed for another reason. Earlier teams, if any, are kept.
        case failed(String)
    }

    /// One lane and its PRs.
    public struct LaneGroup: Identifiable, Equatable, Sendable {
        public var lane: Lane
        public var pullRequests: [ClassifiedPR]
        public var id: Lane { lane }
    }

    // MARK: State

    public private(set) var auth: AuthState = .signedOut
    /// Why the last sign-in attempt failed.
    public private(set) var authError: String?
    public private(set) var isCLIInstalled: Bool
    public var isDeviceFlowAvailable: Bool { dependencies.deviceFlow != nil }

    public private(set) var watchedRepos: [String]
    public private(set) var views: [SavedView]
    public var selectedViewID: UUID? {
        didSet { if oldValue != selectedViewID { updateConfig { $0.selectedViewID = selectedViewID } } }
    }
    public private(set) var needsOnboarding: Bool

    /// Repos for the picker, most recently pushed first.
    public private(set) var repoChoices: [Repo] = []
    public private(set) var isLoadingRepos = false
    public private(set) var repoLoadError: String?

    /// Every open PR in the watched repos, classified for the viewer.
    public private(set) var pullRequests: [ClassifiedPR] = []
    public private(set) var lastUpdated: Date?
    public private(set) var isRefreshing = false
    public private(set) var connection: ConnectionState = .idle
    /// Watched repos the last poll couldn't read.
    public private(set) var failedRepos: [String] = []
    public private(set) var rateLimit: RateLimit?
    /// The most recent events, newest last, up to 50.
    public private(set) var recentEvents: [PREvent] = []
    /// The viewer's teams in the watched repos' organizations, as lowercased `org/slug`.
    /// A review requested from one of them counts as requested from the viewer.
    public private(set) var viewerTeams: Set<String> = []
    public private(set) var teamAccess: TeamAccess = .unknown

    /// Global notification settings. Change with `setNotificationSettings`.
    public private(set) var notificationSettings: NotificationSettings
    /// Seconds between polls when the rate limit allows. Change with `setPollInterval`.
    public private(set) var pollInterval: TimeInterval
    /// Check-name substrings treated as guards. Change with `setGuardCheckPatterns`.
    public private(set) var guardCheckPatterns: [String]

    /// Called on the main actor with each poll's events. The notification layer sets this.
    public var onEvents: (@MainActor ([PREvent]) -> Void)?

    public var viewer: Viewer? {
        if case .signedIn(let viewer, _) = auth { viewer } else { nil }
    }

    public var authMethod: AuthMethod? {
        if case .signedIn(_, let method) = auth { method } else { nil }
    }

    // MARK: Private

    @ObservationIgnored private let dependencies: PRStoreDependencies
    @ObservationIgnored private var config: AppConfig
    @ObservationIgnored private var api: (any GitHubAPI)?
    @ObservationIgnored private var snapshot: TransitionSnapshot?
    @ObservationIgnored private var queueDrops: [String: QueueDrop] = [:]
    @ObservationIgnored private var rawPullRequests: [PullRequest] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var nextDelay: TimeInterval?
    @ObservationIgnored private var policy: PollPolicy
    @ObservationIgnored private var queueDropDebouncer = QueueDropDebouncer()
    @ObservationIgnored private var teamsCheckedAt: Date?
    @ObservationIgnored private var teamsCheckedOrgs: Set<String> = []

    /// How long team membership is cached before it's asked again.
    public static let teamRefreshInterval: TimeInterval = 6 * 3600

    public init(dependencies: PRStoreDependencies) {
        self.dependencies = dependencies
        let config = (try? dependencies.config.load()) ?? AppConfig()
        self.config = config
        self.watchedRepos = config.watchedRepos
        self.views = (try? dependencies.views.load()) ?? BuiltInViews.defaults
        self.needsOnboarding = !config.onboardingComplete
        self.isCLIInstalled = dependencies.cliInstalled()
        self.policy = PollPolicy(baseInterval: config.pollInterval)
        self.notificationSettings = config.notifications ?? NotificationSettings()
        self.pollInterval = config.pollInterval
        self.guardCheckPatterns = config.guardCheckPatterns
        self.snapshot = try? dependencies.snapshot.load()
        self.queueDrops = snapshot?.queueDrops ?? [:]
        self.selectedViewID = config.selectedViewID ?? views.first?.id

        if let method = config.authMethod {
            api = dependencies.makeAPI(tokenProvider(for: method))
            auth = config.viewer.map { .signedIn($0, method) } ?? .signingIn(method)
        }
    }

    // MARK: Derived

    public var selectedView: SavedView? {
        views.first { $0.id == selectedViewID } ?? views.first
    }

    /// PRs that match the view, in lane order.
    public func pullRequests(in viewID: UUID?) -> [ClassifiedPR] {
        guard let context = filterContext, let view = views.first(where: { $0.id == viewID }) else { return [] }
        return pullRequests.filter { view.matches($0.pr, in: context) }
    }

    /// What rules are evaluated against: the viewer, their teams, and the lanes as classified.
    public var filterContext: FilterContext? {
        guard let login = viewer?.login else { return nil }
        return FilterContext(
            viewer: login, viewerTeams: viewerTeams,
            lanes: Dictionary(pullRequests.map { ($0.id, $0.info.lane) }, uniquingKeysWith: { a, _ in a }),
            classification: classificationContext
        )
    }

    private var classificationContext: ClassificationContext {
        ClassificationContext(now: dependencies.now(), guardCheckPatterns: config.guardCheckPatterns, queueDrops: queueDrops, viewerTeams: viewerTeams)
    }

    /// The four lanes for a view, always all four and in order, each sorted for its lane.
    public func lanes(for viewID: UUID?) -> [LaneGroup] {
        Self.lanes(pullRequests(in: viewID))
    }

    public static func lanes(_ prs: [ClassifiedPR]) -> [LaneGroup] {
        Lane.allCases.map { lane in
            let inLane = prs.filter { $0.info.lane == lane }
            let sorted: [ClassifiedPR] = switch lane {
            case .inMergeQueue:
                inLane.sorted { ($0.pr.mergeQueueEntry?.position ?? .max) < ($1.pr.mergeQueueEntry?.position ?? .max) }
            default:
                inLane.sorted { $0.pr.updatedAt > $1.pr.updatedAt }
            }
            return LaneGroup(lane: lane, pullRequests: sorted)
        }
    }

    /// Views shown in the menubar popover: the pinned ones, or all when none is pinned.
    public var menuBarViews: [SavedView] {
        let pinned = views.filter(\.pinnedToMenubar)
        return pinned.isEmpty ? views : pinned
    }

    /// PRs in any menubar view, each once.
    public var menuBarPullRequests: [ClassifiedPR] {
        guard let context = filterContext else { return [] }
        let menuViews = menuBarViews
        return pullRequests.filter { pr in menuViews.contains { $0.matches(pr.pr, in: context) } }
    }

    /// The menubar badge: PRs in the menubar views whose lane is "Your move".
    public var yourMoveCount: Int {
        menuBarPullRequests.filter { $0.info.lane == .yourMove }.count
    }

    // MARK: Sign-in

    /// Re-checks whether `gh` is installed, for the onboarding screen.
    public func refreshCLIDetection() {
        isCLIInstalled = dependencies.cliInstalled()
    }

    public func signInWithGitHubCLI() async {
        await signIn(method: .githubCLI, tokens: dependencies.cliTokens)
    }

    /// Checks a pasted token with GitHub, then keeps it in the Keychain.
    public func signIn(pastedToken: String) async {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        await signIn(method: .pastedToken, tokens: StaticTokenProvider(token), saveToken: token)
    }

    /// Starts the device flow. Shows the code via `auth`, then polls in the background.
    public func beginDeviceFlow() async {
        guard let flow = dependencies.deviceFlow else { return }
        authError = nil
        auth = .signingIn(.deviceFlow)
        do {
            let code = try await flow.requestCode()
            auth = .awaitingDeviceApproval(code)
            deviceTask = Task { [weak self] in
                do {
                    let token = try await flow.pollForToken(code)
                    await self?.signIn(method: .deviceFlow, tokens: StaticTokenProvider(token), saveToken: token)
                } catch is CancellationError {
                } catch {
                    self?.failSignIn(Self.describe(error))
                }
            }
        } catch {
            failSignIn(Self.describe(error))
        }
    }

    public func cancelDeviceFlow() {
        deviceTask?.cancel()
        deviceTask = nil
        if case .awaitingDeviceApproval = auth { auth = .signedOut }
    }

    public func signOut() {
        stop()
        deviceTask?.cancel()
        if config.authMethod != .githubCLI {
            dependencies.secrets.write("", for: SecretKeys.githubToken)
        }
        api = nil
        auth = .signedOut
        pullRequests = []
        rawPullRequests = []
        repoChoices = []
        viewerTeams = []
        teamAccess = .unknown
        teamsCheckedAt = nil
        teamsCheckedOrgs = []
        lastUpdated = nil
        connection = .idle
        recentEvents = []
        queueDropDebouncer.reset()
        updateConfig {
            $0.authMethod = nil
            $0.viewer = nil
        }
    }

    private func signIn(method: AuthMethod, tokens: any TokenProvider, saveToken: String? = nil) async {
        authError = nil
        auth = .signingIn(method)
        do {
            let viewer = try await dependencies.makeAPI(tokens).viewer()
            if let saveToken {
                guard dependencies.secrets.write(saveToken, for: SecretKeys.githubToken) else {
                    failSignIn("Couldn't save the token in the Keychain.")
                    return
                }
            }
            api = dependencies.makeAPI(tokenProvider(for: method))
            auth = .signedIn(viewer, method)
            connection = .idle
            updateConfig {
                $0.authMethod = method
                $0.viewer = viewer
            }
        } catch {
            failSignIn(Self.describe(error))
        }
    }

    private func failSignIn(_ message: String) {
        auth = .signedOut
        authError = message
    }

    private func tokenProvider(for method: AuthMethod) -> any TokenProvider {
        switch method {
        case .githubCLI: dependencies.cliTokens
        case .deviceFlow, .pastedToken: StoredTokenProvider(store: dependencies.secrets)
        }
    }

    // MARK: Onboarding and settings

    public func loadRepoChoices() async {
        guard let api else { return }
        isLoadingRepos = true
        repoLoadError = nil
        defer { isLoadingRepos = false }
        do {
            repoChoices = try await api.repositories()
        } catch {
            repoLoadError = Self.describe(error)
        }
    }

    /// Repos to pre-check in the picker.
    public var suggestedRepos: [String] {
        guard let login = viewer?.login else { return [] }
        return RepoPicker.suggested(repoChoices, viewer: login, now: dependencies.now())
    }

    public func setWatchedRepos(_ repos: [String]) {
        var seen = Set<String>()
        watchedRepos = repos.filter { seen.insert($0.lowercased()).inserted }
        updateConfig { $0.watchedRepos = watchedRepos }
    }

    /// Finishes onboarding with the chosen repos and starter views, and starts polling.
    public func completeOnboarding(repos: [String], views starterViews: [SavedView]) {
        setWatchedRepos(repos)
        if !starterViews.isEmpty { replaceViews(starterViews) }
        selectedViewID = views.first?.id
        needsOnboarding = false
        updateConfig { $0.onboardingComplete = true }
        start()
    }

    // MARK: Views

    /// Adds the view, or replaces the one with the same ID.
    public func saveView(_ view: SavedView) {
        if let index = views.firstIndex(where: { $0.id == view.id }) {
            views[index] = view
        } else {
            views.append(view)
        }
        persistViews()
        reclassify()
    }

    public func deleteView(id: UUID) {
        views.removeAll { $0.id == id }
        if selectedViewID == id { selectedViewID = views.first?.id }
        persistViews()
    }

    public func moveViews(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { views[$0] }
        var rest = views.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        views = rest
        persistViews()
    }

    public func replaceViews(_ newViews: [SavedView]) {
        views = newViews
        if !views.contains(where: { $0.id == selectedViewID }) { selectedViewID = views.first?.id }
        persistViews()
    }

    private func persistViews() {
        try? dependencies.views.save(views)
    }

    // MARK: Polling

    /// Starts the polling loop. Safe to call more than once.
    public func start() {
        guard pollTask == nil, api != nil, !needsOnboarding else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                guard let delay = self.nextDelay else { break }
                do { try await self.dependencies.sleep(delay) } catch { break }
            }
            self?.pollTask = nil
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Polls now and restarts the timer, unless a poll is already running. For the
    /// Refresh button, wake from sleep, and opening the popover.
    public func refreshNow() {
        guard !isRefreshing else { return }
        stop()
        start()
    }

    /// One poll: open PRs, check detail for PRs in a view, transitions, classification.
    public func refresh() async {
        guard let api, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let before = rateLimit
        do {
            var login = viewer?.login
            if login == nil, let method = config.authMethod {
                let fetched = try await api.viewer()
                auth = .signedIn(fetched, method)
                updateConfig { $0.viewer = fetched }
                login = fetched.login
            }
            guard let login else { return }
            await refreshTeamsIfNeeded(api: api, login: login)

            let light = try await api.openPullRequests(in: watchedRepos)
            let watched = Set(watchedRepos.map { $0.lowercased() })
            let failed = Set(light.failedRepos.map { $0.lowercased() })
            // Keep PRs from repos that failed this time, so they don't look closed.
            let carried = rawPullRequests.filter { failed.contains($0.repo.lowercased()) && watched.contains($0.repo.lowercased()) }

            let lightContext = FilterContext(viewer: login, viewerTeams: viewerTeams, classification: classificationContext)
            let needDetail = light.pullRequests.filter { pr in views.contains { $0.rule.mightMatch(pr, in: lightContext) } }
            let details = needDetail.isEmpty ? [:] : try await api.checkDetails(for: needDetail)
            let current = light.pullRequests.map { pr -> PullRequest in
                var pr = pr
                pr.checks = details[pr.id]
                return pr
            } + carried

            let now = dependencies.now()
            let detector = TransitionDetector(guardCheckPatterns: config.guardCheckPatterns)
            let (events, newSnapshot) = detector.detect(previous: snapshot, current: current, viewer: login, views: views, now: now, viewerTeams: viewerTeams)
            snapshot = newSnapshot
            try? dependencies.snapshot.save(newSnapshot)
            queueDrops = newSnapshot.queueDrops
            rawPullRequests = current
            failedRepos = light.failedRepos
            reclassify()
            lastUpdated = now
            connection = .upToDate
            consecutiveFailures = 0
            rateLimit = await api.latestRateLimit()
            nextDelay = policy.interval(after: rateLimit, pollCost: Self.cost(before: before, after: rateLimit), now: now)

            // "Dropped from merge queue" waits a poll, in case GitHub was mid-merge.
            let delivered = queueDropDebouncer.process(events, current: current, failedRepos: light.failedRepos)
            if !delivered.isEmpty {
                recentEvents = Array((recentEvents + delivered).suffix(50))
                onEvents?(delivered)
            }
        } catch is CancellationError {
            nextDelay = nil
        } catch {
            consecutiveFailures += 1
            let gitHubError = (error as? GitHubError) ?? .graphQL(messages: [Self.describe(error)])
            connection = switch gitHubError {
            case .unauthorized, .auth: .tokenRejected
            case .offline: .offline
            case .rateLimited(let resetAt): .rateLimited(until: resetAt)
            case .secondaryRateLimit(let retry): .secondaryRateLimited(until: retry.map { dependencies.now().addingTimeInterval($0) })
            default: .failed(Self.describe(error))
            }
            rateLimit = await api.latestRateLimit() ?? rateLimit
            nextDelay = policy.interval(after: gitHubError, attempt: consecutiveFailures, now: dependencies.now())
        }
    }

    /// Re-runs classification, such as after a view changed. No network.
    public func reclassify() {
        guard let login = viewer?.login else { pullRequests = []; return }
        pullRequests = PRClassifier.classify(rawPullRequests, viewer: login, context: classificationContext)
    }

    /// Asks GitHub for the viewer's teams when the watched organizations changed or the
    /// cache is older than `teamRefreshInterval`. Never fails the poll: without access,
    /// "review requested from my teams" falls back to requests by name.
    private func refreshTeamsIfNeeded(api: any GitHubAPI, login: String) async {
        let orgs = Set(watchedRepos.compactMap { $0.split(separator: "/").first.map { $0.lowercased() } })
        let now = dependencies.now()
        if orgs == teamsCheckedOrgs, let checked = teamsCheckedAt, now.timeIntervalSince(checked) < Self.teamRefreshInterval { return }
        do {
            let memberships = try await api.viewerTeams(login: login, organizations: orgs.sorted())
            viewerTeams = memberships.teams
            teamAccess = memberships.missingScope ? .missingScope : .available
            teamsCheckedAt = now
            teamsCheckedOrgs = orgs
        } catch is CancellationError {
        } catch {
            // Try again next poll; keep what we had.
            teamAccess = .failed(Self.describe(error))
        }
    }

    // MARK: Settings

    public func setNotificationSettings(_ settings: NotificationSettings) {
        notificationSettings = settings
        updateConfig { $0.notifications = settings }
    }

    /// The shortest interval allowed between polls.
    public static let minimumPollInterval: TimeInterval = 30

    /// Takes effect from the next poll.
    public func setPollInterval(_ seconds: TimeInterval) {
        let seconds = max(Self.minimumPollInterval, seconds)
        pollInterval = seconds
        policy.baseInterval = seconds
        updateConfig { $0.pollInterval = seconds }
    }

    /// Trims, drops empties and duplicates, and reclassifies right away.
    public func setGuardCheckPatterns(_ patterns: [String]) {
        var seen = Set<String>()
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guardCheckPatterns = cleaned
        updateConfig { $0.guardCheckPatterns = cleaned }
        reclassify()
    }

    // MARK: Helpers

    private func updateConfig(_ change: (inout AppConfig) -> Void) {
        change(&config)
        try? dependencies.config.save(config)
    }

    static func cost(before: RateLimit?, after: RateLimit?) -> Int {
        guard let before, let after, before.resetAt == after.resetAt else { return after?.cost ?? 1 }
        return max(1, before.remaining - after.remaining)
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as GitHubError:
            switch error {
            case .unauthorized: return "GitHub rejected the token."
            case .offline: return "Can't reach GitHub. Check your connection."
            case .rateLimited: return "GitHub's rate limit ran out."
            case .secondaryRateLimit: return "GitHub asked us to slow down."
            case .http(let status): return "GitHub returned an error (HTTP \(status))."
            case .graphQL(let messages): return messages.first ?? "GitHub returned an error."
            case .decoding: return "GitHub's response wasn't what we expected."
            case .auth(let auth): return describe(auth)
            }
        case let error as AuthError:
            switch error {
            case .cliNotFound: return "The GitHub CLI isn't installed."
            case .cliNotSignedIn: return "The GitHub CLI isn't signed in. Run `gh auth login` in Terminal."
            case .noSavedToken: return "No saved token. Sign in again."
            }
        case let error as DeviceFlowError:
            switch error {
            case .notConfigured: return "Sign in with GitHub isn't set up in this build."
            case .expired: return "The code expired. Start again."
            case .accessDenied: return "Sign-in was cancelled on GitHub."
            case .server(let code): return "GitHub said: \(code)."
            case .badResponse: return "GitHub's response wasn't what we expected."
            }
        default:
            return error.localizedDescription
        }
    }
}
