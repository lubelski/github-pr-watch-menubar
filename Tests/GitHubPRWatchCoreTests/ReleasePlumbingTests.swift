import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct AppIdentityTests {
    @Test func namesFollowTheRepo() {
        #expect(AppIdentity.repoName == "github-pr-watch-menubar")
        #expect(AppIdentity.bundleIdentifier == "dev.lubelski.github-pr-watch-menubar")
        #expect(AppIdentity.gitHubRepository == "lubelski/github-pr-watch-menubar")
    }

    @Test func keychainAndDataFolderUseTheNewNames() {
        #expect(KeychainSecrets.service == AppIdentity.bundleIdentifier)
        #expect(JSONFileStore<AppConfig>.applicationSupportDirectory.lastPathComponent == "github-pr-watch-menubar")
    }
}

@Suite struct AppUpdatesTests {
    @Test func onlyABundleWithAFeedAndAKeyUpdates() {
        #expect(!AppUpdates.hasFeed(nil))
        #expect(!AppUpdates.hasFeed([:]))
        #expect(!AppUpdates.hasFeed(["SUFeedURL": "https://example.com/appcast.xml"]))
        #expect(!AppUpdates.hasFeed(["SUFeedURL": "", "SUPublicEDKey": "key"]))
        #expect(!AppUpdates.hasFeed(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": ""]))
        #expect(AppUpdates.hasFeed(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"]))
    }

    @Test func relaunchesOnlyWhenIdle() {
        #expect(AppUpdates.mayRelaunch(.init()))
        #expect(AppUpdates.wait(for: .init(polling: true)) == .polling)
        #expect(AppUpdates.wait(for: .init(inUse: true)) == .inUse)
        #expect(AppUpdates.wait(for: .init(signingIn: true)) == .signingIn)
        // A sign-in matters most: a relaunch would throw away a device-flow code.
        #expect(AppUpdates.wait(for: .init(polling: true, signingIn: true, inUse: true)) == .signingIn)
        #expect(AppUpdates.wait(for: .init(polling: true, inUse: true)) == .inUse)
    }
}

@Suite struct BuildInfoTests {
    @Test func readsTheInfoPlistThatBundleShWrites() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "57", "PRWatchGitCommit": "abc1234-dirty",
            "CFBundleIdentifier": "dev.lubelski.github-pr-watch-menubar",
        ]
        let build = BuildInfo(info: info, signing: "Signed ad hoc")
        #expect(build.version == "0.2.0")
        #expect(build.build == "57")
        #expect(build.versionAndBuild == "0.2.0 (57)")
        #expect(build.commit == "abc1234-dirty")
        #expect(build.bundleIdentifier == "dev.lubelski.github-pr-watch-menubar")
        #expect(!build.updates)
    }

    @Test func aReleaseBuildHasUpdates() {
        let build = BuildInfo(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"], signing: "")
        #expect(build.updates)
    }

    @Test func outsideABundleSaysSo() {
        let build = BuildInfo(info: nil, signing: "Not signed")
        #expect(build.versionAndBuild == "development (none)")
        #expect(build.commit == "unknown")
        #expect(build.bundleIdentifier == "none")
    }

    @Test func describesTheSignature() {
        #expect(BuildInfo.describeSigning(isSigned: false, isAdHoc: false, teamID: nil) == "Not signed")
        #expect(BuildInfo.describeSigning(isSigned: true, isAdHoc: true, teamID: nil) == "Signed ad hoc")
        #expect(BuildInfo.describeSigning(isSigned: true, isAdHoc: false, teamID: "TEAM000000") == "Signed by team TEAM000000")
    }
}

/// A stand-in with cases, since `Experiment` has none yet.
private enum SampleExperiment: String, ExperimentDefinition {
    case groupByRepo, compactRows
    var key: String { ExperimentSwitch.key(rawValue.prefix(1).uppercased() + rawValue.dropFirst()) }
    var title: String { rawValue }
    var summary: String { "" }
}

@Suite struct ExperimentTests {
    private func throwawayDefaults() -> UserDefaults {
        let name = "dev.lubelski.github-pr-watch-menubar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func everyExperimentStartsOff() {
        let defaults = throwawayDefaults()
        #expect(SampleExperiment.allCases.allSatisfy { !$0.isOn(defaults) })
        #expect(SampleExperiment.enabled(defaults).isEmpty)
        #expect(Experiment.enabled(defaults).isEmpty)
    }

    @Test func aSwitchIsKeptUnderItsKey() {
        let defaults = throwawayDefaults()
        SampleExperiment.groupByRepo.set(true, defaults)
        #expect(defaults.bool(forKey: "ExperimentGroupByRepo"))
        #expect(SampleExperiment.groupByRepo.isOn(defaults))
        #expect(!SampleExperiment.compactRows.isOn(defaults))
        #expect(SampleExperiment.enabled(defaults) == [.groupByRepo])
        SampleExperiment.groupByRepo.set(false, defaults)
        #expect(SampleExperiment.enabled(defaults).isEmpty)
    }

    @Test func keysAreUniqueAndPrefixed() {
        let keys = Experiment.allCases.map(\.key) + SampleExperiment.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix("Experiment") })
    }
}

@MainActor
@Suite struct DiagnosticsTests {
    let secretToken = "github_pat_placeholderSECRET0123456789"
    let build = BuildInfo(
        version: "0.2.0", build: "57", commit: "abc1234", bundleIdentifier: AppIdentity.bundleIdentifier,
        signing: "Signed ad hoc", updates: false)

    private func signedInStore() async -> PRStore {
        let store = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(), views: SampleData.views))
        await store.signIn(pastedToken: secretToken)
        store.setWatchedRepos(["acme/web", "acme/api"])
        await store.refresh()
        return store
    }

    @Test func copiedTextHasNoTokenLoginOrRepoNames() async {
        let store = await signedInStore()
        #expect(store.viewer?.login == "rchen")
        #expect(store.authMethod == .pastedToken)
        #expect(!store.pullRequests.isEmpty)
        let report = DiagnosticsReport(
            store: store, build: build, dataFolder: URL(fileURLWithPath: "/Users/placeholder/Library/Application Support/github-pr-watch-menubar"),
            home: "/Users/placeholder")
        let text = report.plainText()
        #expect(!text.contains(secretToken))
        #expect(!text.contains("placeholderSECRET"))
        #expect(!text.contains("rchen"))
        #expect(!text.contains("Riley"))
        #expect(!text.contains("acme/"))
        #expect(!text.contains("/Users/placeholder"))
        for pr in store.pullRequests {
            #expect(!text.contains(pr.pr.title))
        }
    }

    @Test func copiedTextSaysHowThingsStand() async {
        let store = await signedInStore()
        let text = DiagnosticsReport(store: store, build: build, home: "/nowhere").plainText()
        #expect(text.contains("Version: 0.2.0 (57)"))
        #expect(text.contains("Commit: abc1234"))
        #expect(text.contains("Bundle identifier: dev.lubelski.github-pr-watch-menubar"))
        #expect(text.contains("Signed in: Yes"))
        #expect(text.contains("Sign-in method: Pasted token (in the Keychain)"))
        #expect(text.contains("Watched repos: 2"))
        #expect(text.contains("Last poll result: Worked"))
        #expect(!text.contains("Last poll started: Never"))
        #expect(text.contains("Experiments on: None"))
    }

    @Test func gitHubCLITokenIsNotCopiedEither() async {
        let store = PRStore(dependencies: .inMemory(api: StaticGitHubAPI()))
        await store.signInWithGitHubCLI()
        let text = DiagnosticsReport(store: store, build: build).plainText()
        // The in-memory CLI token provider answers with this placeholder.
        #expect(!text.contains("placeholder-token"))
        #expect(text.contains("GitHub CLI login"))
    }

    @Test func beforeAnyPoll() {
        let store = PRStore(dependencies: .inMemory(api: StaticGitHubAPI()))
        let text = DiagnosticsReport(store: store, build: build).plainText()
        #expect(text.contains("Signed in: No"))
        #expect(text.contains("Last poll started: Never"))
        #expect(text.contains("Last poll result: No poll has finished yet"))
        #expect(text.contains("Rate limit: Not known yet"))
    }

    @Test func homeFolderIsAbbreviated() {
        #expect(DiagnosticsReport.abbreviate("/Users/a/Library/x", home: "/Users/a") == "~/Library/x")
        #expect(DiagnosticsReport.abbreviate("/Users/ab/x", home: "/Users/a") == "/Users/ab/x")
        #expect(DiagnosticsReport.abbreviate("/tmp/x", home: "") == "/tmp/x")
    }
}
