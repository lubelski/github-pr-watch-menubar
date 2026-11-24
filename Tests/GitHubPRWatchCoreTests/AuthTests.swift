import Foundation
import Testing
@testable import GitHubPRWatchCore

struct FakeRunner: CommandRunner {
    var output: String?
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Data {
        #expect(arguments == ["auth", "token", "--hostname", "github.com"])
        guard let output else { throw CommandFailed() }
        return Data(output.utf8)
    }
}

@Suite struct GitHubCLITests {
    @Test func locatesOnPathFirst() {
        let found = GitHubCLI.locate(path: "/usr/bin:/custom/bin", home: "/Users/placeholder") { $0 == "/custom/bin/gh" || $0 == "/opt/homebrew/bin/gh" }
        #expect(found?.path == "/custom/bin/gh")
    }

    @Test func fallsBackToKnownDirectories() {
        #expect(GitHubCLI.locate(path: "/usr/bin", home: "/Users/placeholder") { $0 == "/opt/homebrew/bin/gh" }?.path == "/opt/homebrew/bin/gh")
        #expect(GitHubCLI.locate(path: nil, home: "/Users/placeholder") { $0 == "/usr/local/bin/gh" }?.path == "/usr/local/bin/gh")
        #expect(GitHubCLI.locate(path: "", home: "/Users/placeholder") { $0 == "/Users/placeholder/.local/bin/gh" }?.path == "/Users/placeholder/.local/bin/gh")
        #expect(GitHubCLI.locate(path: "", home: "/Users/placeholder") { _ in false } == nil)
    }

    @Test func readsTokenEachTime() async throws {
        let cli = GitHubCLI(runner: FakeRunner(output: "gho_placeholder\n"), locate: { URL(fileURLWithPath: "/opt/homebrew/bin/gh") })
        #expect(try await cli.token() == "gho_placeholder")
    }

    @Test func notInstalled() async {
        let cli = GitHubCLI(runner: FakeRunner(output: "x"), locate: { nil })
        #expect(!cli.isInstalled)
        await #expect(throws: AuthError.cliNotFound) { try await cli.token() }
    }

    @Test func notSignedIn() async {
        let failing = GitHubCLI(runner: FakeRunner(output: nil), locate: { URL(fileURLWithPath: "/x/gh") })
        await #expect(throws: AuthError.cliNotSignedIn) { try await failing.token() }
        let empty = GitHubCLI(runner: FakeRunner(output: "  \n"), locate: { URL(fileURLWithPath: "/x/gh") })
        await #expect(throws: AuthError.cliNotSignedIn) { try await empty.token() }
    }
}

@Suite struct SecretTests {
    @Test func inMemorySecrets() {
        let secrets = InMemorySecrets()
        #expect(secrets.read("k") == nil)
        secrets.write("  value \n", for: "k")
        #expect(secrets.read("k") == "value")
        secrets.write("", for: "k")
        #expect(secrets.read("k") == nil)
    }

    @Test func storedTokenProvider() async throws {
        let secrets = InMemorySecrets([SecretKeys.githubToken: "abc"])
        #expect(try await StoredTokenProvider(store: secrets).token() == "abc")
        await #expect(throws: AuthError.noSavedToken) { try await StoredTokenProvider(store: InMemorySecrets()).token() }
    }
}

@Suite struct DeviceFlowTests {
    final class Clock: @unchecked Sendable {
        var now = t0
        var slept: [TimeInterval] = []
    }

    func flow(_ transport: FakeTransport, clock: Clock) -> DeviceFlow {
        DeviceFlow(
            clientID: "placeholder-client", transport: transport,
            now: { clock.now },
            sleep: { seconds in clock.slept.append(seconds); clock.now = clock.now.addingTimeInterval(seconds) }
        )
    }

    let codeJSON = #"{"device_code":"dc","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#

    @Test func notConfiguredWithoutClientID() async {
        let f = DeviceFlow(clientID: "", transport: FakeTransport(json: "{}"))
        await #expect(throws: DeviceFlowError.notConfigured) { try await f.requestCode() }
        #expect(OAuthConfig.clientID.isEmpty == !OAuthConfig.isDeviceFlowAvailable)
    }

    @Test func requestCode() async throws {
        let transport = FakeTransport(json: codeJSON)
        let code = try await flow(transport, clock: Clock()).requestCode()
        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.verificationURL.absoluteString == "https://github.com/login/device")
        #expect(code.expiresAt == t0.addingTimeInterval(900))
        #expect(code.interval == 5)
        #expect(transport.bodies[0].contains("client_id=placeholder-client"))
        #expect(transport.bodies[0].contains("scope=repo%20read:org"))
    }

    @Test func pollsThroughPendingAndSlowDown() async throws {
        let replies = [
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down","interval":10}"#,
            #"{"error":"authorization_pending"}"#,
            #"{"access_token":"gho_placeholder","token_type":"bearer","scope":"repo"}"#,
        ]
        let transport = FakeTransport { _, i in (200, [:], replies[i]) }
        let clock = Clock()
        let code = DeviceCode(deviceCode: "dc", userCode: "U", verificationURL: URL(string: "https://github.com/login/device")!, expiresAt: t0.addingTimeInterval(900), interval: 5)
        let token = try await flow(transport, clock: clock).pollForToken(code)
        #expect(token == "gho_placeholder")
        #expect(clock.slept == [5, 5, 10, 10])
        #expect(transport.bodies[0].contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
        #expect(transport.bodies[0].contains("device_code=dc"))
    }

    @Test func slowDownWithoutIntervalAddsFive() async throws {
        let replies = [#"{"error":"slow_down"}"#, #"{"access_token":"t"}"#]
        let transport = FakeTransport { _, i in (200, [:], replies[i]) }
        let clock = Clock()
        let code = DeviceCode(deviceCode: "dc", userCode: "U", verificationURL: URL(string: "https://x")!, expiresAt: t0.addingTimeInterval(900), interval: 5)
        _ = try await flow(transport, clock: clock).pollForToken(code)
        #expect(clock.slept == [5, 10])
    }

    @Test func expiresLocally() async {
        let transport = FakeTransport(json: #"{"error":"authorization_pending"}"#)
        let code = DeviceCode(deviceCode: "dc", userCode: "U", verificationURL: URL(string: "https://x")!, expiresAt: t0.addingTimeInterval(12), interval: 5)
        await #expect(throws: DeviceFlowError.expired) { try await flow(transport, clock: Clock()).pollForToken(code) }
        #expect(transport.bodies.count == 2)
    }

    @Test func serverSaysExpiredOrDenied() async {
        let code = DeviceCode(deviceCode: "dc", userCode: "U", verificationURL: URL(string: "https://x")!, expiresAt: t0.addingTimeInterval(900), interval: 5)
        await #expect(throws: DeviceFlowError.expired) {
            try await flow(FakeTransport(json: #"{"error":"expired_token"}"#), clock: Clock()).pollForToken(code)
        }
        await #expect(throws: DeviceFlowError.accessDenied) {
            try await flow(FakeTransport(json: #"{"error":"access_denied"}"#), clock: Clock()).pollForToken(code)
        }
        await #expect(throws: DeviceFlowError.server("device_flow_disabled")) {
            try await flow(FakeTransport(json: #"{"error":"device_flow_disabled"}"#), clock: Clock()).pollForToken(code)
        }
    }
}

@Suite struct PollPolicyTests {
    let policy = PollPolicy()

    @Test func baseIntervalWhenBudgetIsHealthy() {
        let limit = RateLimit(limit: 5000, cost: 3, remaining: 4000, resetAt: minutes(30))
        #expect(policy.interval(after: limit, pollCost: 5, now: t0) == 60)
        #expect(policy.interval(after: nil, pollCost: 5, now: t0) == 60)
    }

    @Test func spreadsOutWhenBudgetIsLow() {
        // 100 points left, 10 per poll, 50 minutes to reset: 8 polls in 3000s → 375s.
        let limit = RateLimit(limit: 5000, cost: 10, remaining: 100, resetAt: minutes(50))
        #expect(policy.interval(after: limit, pollCost: 10, now: t0) == 375)
    }

    @Test func waitsForResetWhenEmpty() {
        let limit = RateLimit(limit: 5000, cost: 1, remaining: 0, resetAt: minutes(10))
        #expect(policy.interval(after: limit, pollCost: 1, now: t0) == 605)
    }

    @Test func errors() {
        #expect(policy.interval(after: .unauthorized, attempt: 1, now: t0) == nil)
        #expect(policy.interval(after: .auth(.cliNotSignedIn), attempt: 1, now: t0) == nil)
        #expect(policy.interval(after: .offline, attempt: 1, now: t0) == 30)
        #expect(policy.interval(after: .offline, attempt: 3, now: t0) == 120)
        #expect(policy.interval(after: .offline, attempt: 30, now: t0) == 900)
        #expect(policy.interval(after: .secondaryRateLimit(retryAfter: 90), attempt: 1, now: t0) == 90)
        #expect(policy.interval(after: .secondaryRateLimit(retryAfter: nil), attempt: 2, now: t0) == 240)
        #expect(policy.interval(after: .rateLimited(resetAt: minutes(20)), attempt: 1, now: t0) == 1205)
        #expect(policy.interval(after: .http(status: 502), attempt: 2, now: t0) == 120)
    }
}

@Suite struct RepoPickerTests {
    let repos = [
        Repo(nameWithOwner: "acme/web", pushedAt: minutes(-60), hasMergeQueue: false),
        Repo(nameWithOwner: "rchen/dotfiles", pushedAt: minutes(-30)),
        Repo(nameWithOwner: "acme/api", pushedAt: minutes(-120), hasMergeQueue: true),
        Repo(nameWithOwner: "acme/fork", isFork: true, pushedAt: minutes(-10)),
        Repo(nameWithOwner: "acme/old", pushedAt: minutes(-60 * 24 * 60)),
        Repo(nameWithOwner: "other/lib", pushedAt: minutes(-200)),
    ]

    @Test func filter() {
        #expect(RepoPicker.filter(repos, query: "").count == repos.count)
        #expect(RepoPicker.filter(repos, query: "ACME w").map(\.nameWithOwner) == ["acme/web"])
        #expect(RepoPicker.filter(repos, query: "zzz").isEmpty)
    }

    @Test func grouped() {
        let groups = RepoPicker.grouped(repos, viewer: me)
        #expect(groups.map(\.owner) == ["acme", "other", "rchen"])
        #expect(groups[0].repos.count == 4)
    }

    @Test func suggestions() {
        #expect(RepoPicker.suggested(repos, viewer: me, now: t0) == ["acme/api", "acme/web", "other/lib"])
        #expect(RepoPicker.suggested(repos, viewer: me, now: t0, limit: 1) == ["acme/api"])
    }
}
