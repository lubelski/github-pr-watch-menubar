import Foundation
import Testing
@testable import GitHubPRWatchCore

// Tests for the rule builder's model: new predicates and operators, nested groups, the
// editable draft, templates, validation, team review requests, and saved-view compatibility.

@Suite struct PredicateOperatorTests {
    @Test func notInvertsAndKeepsUnknown() {
        #expect(Predicate.not(.author(.me)).evaluate(pr(author: me), viewer: me) == false)
        #expect(Predicate.not(.author(.me)).evaluate(pr(author: "apark"), viewer: me) == true)
        #expect(Predicate.not(.ci([.failed])).evaluate(pr(), viewer: me) == nil)
        #expect(Predicate.not(.ci([.failed])).evaluate(pr(checks: [check("a")]), viewer: me) == true)
        #expect(Predicate.not(.label(["wip"])).evaluate(pr(labels: ["WIP"]), viewer: me) == false)
    }

    @Test func unassigned() {
        #expect(Predicate.unassigned.evaluate(pr(assignees: []), viewer: me) == true)
        #expect(Predicate.unassigned.evaluate(pr(assignees: ["apark"]), viewer: me) == false)
        #expect(Predicate.not(.unassigned).evaluate(pr(assignees: ["apark"]), viewer: me) == true)
    }

    @Test func titleContains() {
        let p = PullRequest(id: "x", repo: "acme/web", number: 1, title: "Résumé upload: Fix crash", author: "apark")
        #expect(Predicate.titleContains("resume").evaluate(p, viewer: me) == true)
        #expect(Predicate.titleContains("FIX").evaluate(p, viewer: me) == true)
        #expect(Predicate.titleContains("deploy").evaluate(p, viewer: me) == false)
        #expect(Predicate.not(.titleContains("deploy")).evaluate(p, viewer: me) == true)
    }

    @Test func baseBranch() {
        let p = pr()  // base "main"
        #expect(Predicate.baseBranch(["main", "release"]).evaluate(p, viewer: me) == true)
        #expect(Predicate.baseBranch(["release"]).evaluate(p, viewer: me) == false)
        #expect(Predicate.not(.baseBranch(["main"])).evaluate(p, viewer: me) == false)
    }

    @Test func laneUsesKnownLanesThenClassifies() {
        let ready = pr(checks: [check("a")])  // mine, approved, clean, green: your move
        #expect(Predicate.lane([.yourMove]).evaluate(ready, viewer: me) == true)
        #expect(Predicate.lane([.waiting]).evaluate(ready, viewer: me) == false)
        // Known lanes win over classifying again.
        let context = FilterContext(viewer: me, lanes: [ready.id: .waiting])
        #expect(Predicate.lane([.waiting]).evaluate(ready, in: context) == true)
        // Without check detail the lane can't be known, unless draft or queued decide it.
        #expect(Predicate.lane([.yourMove]).evaluate(pr(), viewer: me) == nil)
        #expect(Predicate.lane([.waiting]).evaluate(pr(draft: true), viewer: me) == true)
        #expect(Predicate.lane([.inMergeQueue]).evaluate(pr(queue: MergeQueueEntry(position: 0)), viewer: me) == true)
    }

    @Test func reviewRequestedByTeamSlugInTheList() {
        let p = pr(author: "apark", reviewRequests: [.team("acme/Platform")])
        #expect(Predicate.reviewRequested(.anyOf(["acme/platform"])).evaluate(p, viewer: me) == true)
        #expect(Predicate.reviewRequested(.anyOf(["acme/web-team"])).evaluate(p, viewer: me) == false)
    }

    @Test func summaries() {
        #expect(Predicate.not(.author(.anyOf(["apark"]))).summary == "not (author is apark)")
        #expect(Predicate.unassigned.summary == "nobody is assigned")
        #expect(Predicate.reviewRequested(.meOrMyTeams).summary == "review requested from me, my teams")
        #expect(Predicate.lane([.yourMove]).summary == "lane is Your move")
    }
}

@Suite struct NestedGroupTests {
    let authoredByMeOrAssigned = FilterCondition.group(FilterRule(match: .any, [.predicate(.author(.me)), .predicate(.assignee(.me))]))

    @Test func mineAndNotDraft() {
        // (authored by me OR assigned to me) AND not draft
        let rule = FilterRule(match: .all, [authoredByMeOrAssigned, .predicate(.isDraft(false))])
        #expect(rule.matches(pr(author: me), viewer: me))
        #expect(rule.matches(pr(author: "jlin-agent", assignees: [me]), viewer: me))
        #expect(!rule.matches(pr(author: me, draft: true), viewer: me))
        #expect(!rule.matches(pr(author: "apark"), viewer: me))
    }

    @Test func authoredByXButAssignedToMe() {
        let rule = FilterRule(match: .all, [.predicate(.author(.anyOf(["jlin-agent"]))), .predicate(.assignee(.me))])
        #expect(rule.matches(pr(author: "jlin-agent", assignees: [me]), viewer: me))
        #expect(!rule.matches(pr(author: "jlin-agent", assignees: ["apark"]), viewer: me))
    }

    @Test func noneGroupInsideAll() {
        let rule = FilterRule(match: .all, [
            .predicate(.repo(["acme/web"])),
            .group(FilterRule(match: .none, [.predicate(.label(["do-not-watch"])), .predicate(.isDraft(true))])),
        ])
        #expect(rule.matches(pr(repo: "acme/web"), viewer: me))
        #expect(!rule.matches(pr(repo: "acme/web", labels: ["do-not-watch"]), viewer: me))
        #expect(!rule.matches(pr(repo: "acme/web", draft: true), viewer: me))
    }

    @Test func unknownInsideNestedGroupPropagates() {
        let rule = FilterRule(match: .all, [.group(FilterRule(match: .any, [.predicate(.ci([.failed])), .predicate(.isDraft(true))]))])
        #expect(rule.evaluate(pr(), viewer: me) == nil)
        #expect(rule.mightMatch(pr(), viewer: me))
        #expect(rule.evaluate(pr(draft: true), viewer: me) == true)
    }
}

@Suite struct TeamReviewTests {
    let teamPR = pr("PR_t", author: "apark", reviewRequests: [.team("acme/platform")], decision: .reviewRequired, state: .blocked)

    @Test func predicateMeOrMyTeams() {
        let withTeams = FilterContext(viewer: me, viewerTeams: ["ACME/Platform"])
        #expect(Predicate.reviewRequested(.meOrMyTeams).evaluate(teamPR, in: withTeams) == true)
        // "me" alone stays by name.
        #expect(Predicate.reviewRequested(.me).evaluate(teamPR, in: withTeams) == false)
        // Without team access it falls back to by-name.
        #expect(Predicate.reviewRequested(.meOrMyTeams).evaluate(teamPR, in: FilterContext(viewer: me)) == false)
        let byName = pr(author: "apark", reviewRequests: [.user(me)])
        #expect(Predicate.reviewRequested(.meOrMyTeams).evaluate(byName, in: FilterContext(viewer: me)) == true)
    }

    @Test func classifierCountsTeamRequestsAsYourMove() {
        let without = PRClassifier.classify(teamPR, viewer: me)
        #expect(without.lane == .waiting)
        let with = PRClassifier.classify(teamPR, viewer: me, context: ClassificationContext(viewerTeams: ["acme/platform"]))
        #expect(with.status.kind == .reviewRequestedFromYou)
        #expect(with.lane == .yourMove)
        // Your own PR requesting your team is not a request to you.
        var mine = teamPR
        mine.author = me
        #expect(PRClassifier.classify(mine, viewer: me, context: ClassificationContext(viewerTeams: ["acme/platform"])).status.kind != .reviewRequestedFromYou)
    }

    @Test func transitionEmitsReviewRequestedForTeam() {
        let detector = TransitionDetector()
        let view = SavedView(name: "Review", rule: FilterRule(match: .all, [.predicate(.reviewRequested(.meOrMyTeams))]), notify: [.reviewRequested])
        var before = teamPR
        before.reviewRequests = []
        let (_, s1) = detector.detect(previous: nil, current: [before], viewer: me, views: [view], now: t0, viewerTeams: ["acme/platform"])
        let (events, _) = detector.detect(previous: s1, current: [teamPR], viewer: me, views: [view], now: minutes(1), viewerTeams: ["acme/platform"])
        #expect(events.map(\.kind) == [.reviewRequested])
        // Without teams, nothing.
        let (_, s2) = detector.detect(previous: nil, current: [before], viewer: me, views: [view], now: t0)
        let (none, _) = detector.detect(previous: s2, current: [teamPR], viewer: me, views: [view], now: minutes(1))
        #expect(none.isEmpty)
    }

    @Test func membershipsAreLowercased() {
        #expect(TeamMemberships(teams: ["Acme/Platform"]).teams == ["acme/platform"])
    }
}

@Suite struct TeamQueryTests {
    let rateLimit = #""rateLimit":{"limit":5000,"cost":1,"remaining":4990,"resetAt":"2026-11-24T07:35:16Z"}"#

    func client(_ transport: FakeTransport) -> GitHubClient {
        GitHubClient(transport: transport, tokens: StaticTokenProvider("placeholder-token"))
    }

    @Test func readsTeamsPerOrgAndPaginates() async throws {
        let rl = rateLimit
        let transport = FakeTransport { request, index in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("\"org\":\"rchen\"") {
                // A user account, not an organization.
                return (200, [:], #"{"data":{\#(rl),"organization":null},"errors":[{"type":"NOT_FOUND","path":["organization"],"message":"Could not resolve to an Organization with the login of 'rchen'."}]}"#)
            }
            if body.contains("\"cursor\":\"T1\"") {
                return (200, [:], #"{"data":{\#(rl),"organization":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"slug":"web-reviewers"}]}}}}"#)
            }
            return (200, [:], #"{"data":{\#(rl),"organization":{"teams":{"pageInfo":{"hasNextPage":true,"endCursor":"T1"},"nodes":[{"slug":"Platform"}]}}}}"#)
        }
        let result = try await client(transport).viewerTeams(login: "rchen", organizations: ["acme", "rchen"])
        #expect(result == TeamMemberships(teams: ["acme/platform", "acme/web-reviewers"]))
        #expect(transport.bodies[0].contains("userLogins"))
        #expect(transport.bodies[0].contains("\"login\":\"rchen\""))
    }

    @Test func missingReadOrgScopeIsReportedNotThrown() async throws {
        let rl = rateLimit
        let transport = FakeTransport(json: #"{"data":{\#(rl),"organization":{"teams":null}},"errors":[{"type":"INSUFFICIENT_SCOPES","locations":[{"line":4,"column":5}],"message":"Your token has not been granted the required scopes to execute this query. The 'teams' field requires one of the following scopes: ['read:org'], but your token has only been granted the: ['repo'] scopes. Please modify your token's scopes at: https://github.com/settings/tokens."}]}"#)
        let result = try await client(transport).viewerTeams(login: "rchen", organizations: ["acme"])
        #expect(result.missingScope)
        #expect(result.teams.isEmpty)
    }

    @Test func fineGrainedTokenWithoutMembersPermission() {
        #expect(GitHubClient.isMissingScope("Resource not accessible by integration"))
        #expect(!GitHubClient.isMissingScope("Could not resolve to an Organization with the login of 'x'."))
    }
}

@MainActor
@Suite struct StoreTeamTests {
    let config = AppConfig(authMethod: .githubCLI, viewer: SampleData.viewer, watchedRepos: ["acme/web", "acme/api"], onboardingComplete: true)

    @Test func teamRequestsBecomeYourMoveWhenTeamsAreReadable() async {
        let s = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(teams: ["acme/platform"]), config: config, views: SampleData.views))
        await s.refresh()
        #expect(s.teamAccess == .available)
        #expect(s.viewerTeams == ["acme/platform"])
        let watch = s.pullRequests.first { $0.id == "PR_watch" }
        #expect(watch?.info.lane == .yourMove)
        let review = SavedView(name: "R", rule: FilterRule(match: .all, [.predicate(.reviewRequested(.meOrMyTeams))]))
        #expect(s.preview(review.rule).matches.map(\.id).contains("PR_watch"))
    }

    @Test func missingScopeFallsBackToByName() async {
        let s = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(teams: nil), config: config, views: SampleData.views))
        await s.refresh()
        #expect(s.teamAccess == .missingScope)
        #expect(s.viewerTeams.isEmpty)
        #expect(s.pullRequests.first { $0.id == "PR_watch" }?.info.status.kind != .reviewRequestedFromYou)
        #expect(s.connection == .upToDate)
    }

    @Test func teamFailureDoesNotFailThePoll() async {
        let api = FailingTeamsAPI()
        let s = PRStore(dependencies: .inMemory(api: api, config: config, views: SampleData.views))
        await s.refresh()
        #expect(s.connection == .upToDate)
        if case .failed = s.teamAccess {} else { Issue.record("expected .failed, got \(s.teamAccess)") }
    }

    @Test func editorHelpers() async {
        let s = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(), config: config, views: SampleData.views))
        await s.refresh()
        #expect(s.knownLogins.contains("jlin-agent"))
        #expect(s.knownLogins.contains("tbrandt"))
        #expect(!s.knownLogins.contains("rchen"))
        #expect(s.knownTeams.contains("acme/platform"))
        #expect(s.knownRepos.prefix(2) == ["acme/web", "acme/api"])
        #expect(s.knownBaseBranches == ["main"])
        let watchlist = ViewDraft(BuiltInViews.watchlist(["tbrandt"]))
        let preview = s.preview(watchlist.rule)
        #expect(preview.matches.map(\.id) == ["PR_watch"])
        let ci = s.preview(FilterRule(match: .all, [.predicate(.ci([.failed]))]))
        // A failing guard check counts as failed CI here; the lanes call it "blocked".
        #expect(Set(ci.matches.map(\.id)) == ["PR_failed", "PR_guard"])
    }

    @Test func duplicateGoesRightAfterTheOriginal() {
        let s = PRStore(dependencies: .inMemory(api: StaticGitHubAPI(), config: config, views: SampleData.views))
        let copy = s.duplicateView(id: BuiltInViews.mineID)
        #expect(copy?.name == "Mine copy")
        #expect(s.views.map(\.name) == ["Mine", "Mine copy", "Needs my review", "Agent PRs", "Watchlist"])
        #expect(s.views[1].rule == BuiltInViews.mine.rule)
        #expect(s.views[1].id != BuiltInViews.mineID)
        s.duplicateView(id: BuiltInViews.mineID)
        #expect(s.views[1].name == "Mine copy 2")
    }
}

/// Answers like `StaticGitHubAPI` but fails the team query.
actor FailingTeamsAPI: GitHubAPI {
    let base = StaticGitHubAPI()
    func viewer() async throws -> Viewer { try await base.viewer() }
    func repositories() async throws -> [Repo] { try await base.repositories() }
    func openPullRequests(in repos: [String]) async throws -> OpenPullRequests { try await base.openPullRequests(in: repos) }
    func checkDetails(for prs: [PullRequest]) async throws -> [String: CheckSummary] { try await base.checkDetails(for: prs) }
    func latestRateLimit() async -> RateLimit? { nil }
    func viewerTeams(login: String, organizations: [String]) async throws -> TeamMemberships { throw GitHubError.http(status: 502) }
}

@Suite struct WatchlistReadyForReviewTests {
    let detector = TransitionDetector()
    let watch = BuiltInViews.watchlist(["tbrandt"])

    @Test func draftIsSilentThenFiresWhenReady() {
        let draft = pr("PR_w", author: "tbrandt", draft: true)
        let ready = pr("PR_w", author: "tbrandt", draft: false)
        let (_, s1) = detector.detect(previous: nil, current: [], viewer: me, views: [watch], now: t0)
        let (e1, s2) = detector.detect(previous: s1, current: [draft], viewer: me, views: [watch], now: minutes(1))
        #expect(e1.isEmpty)
        let (e2, s3) = detector.detect(previous: s2, current: [draft], viewer: me, views: [watch], now: minutes(2))
        #expect(e2.isEmpty)
        let (e3, s4) = detector.detect(previous: s3, current: [ready], viewer: me, views: [watch], now: minutes(3))
        #expect(e3.map(\.kind) == [.newMatch])
        #expect(e3.first?.detail.actor == "tbrandt")
        let (e4, _) = detector.detect(previous: s4, current: [ready], viewer: me, views: [watch], now: minutes(4))
        #expect(e4.isEmpty)
    }

    @Test func viewWithoutADraftRuleStillWaitsForReady() {
        // A view that matches drafts too: the PR is a member while it's a draft, but the
        // banner waits until it's ready for review.
        let anyFromT = SavedView(name: "T", rule: FilterRule(match: .all, [.predicate(.author(.anyOf(["tbrandt"])))]), notify: [.newMatch])
        let draft = pr("PR_w", author: "tbrandt", draft: true)
        var ready = draft
        ready.isDraft = false
        let (_, s1) = detector.detect(previous: nil, current: [], viewer: me, views: [anyFromT], now: t0)
        let (e1, s2) = detector.detect(previous: s1, current: [draft], viewer: me, views: [anyFromT], now: minutes(1))
        #expect(e1.isEmpty)
        #expect(s2.viewMembers[anyFromT.id.uuidString] == ["PR_w"])
        let (e2, _) = detector.detect(previous: s2, current: [ready], viewer: me, views: [anyFromT], now: minutes(2))
        #expect(e2.map(\.kind) == [.newMatch])
    }

    @Test func openedReadyFiresImmediately() {
        let (_, s1) = detector.detect(previous: nil, current: [], viewer: me, views: [watch], now: t0)
        let (e, _) = detector.detect(previous: s1, current: [pr("PR_w", author: "tbrandt")], viewer: me, views: [watch], now: minutes(1))
        #expect(e.map(\.kind) == [.newMatch])
    }
}

@Suite struct ViewDraftTests {
    @Test func roundTripsEveryStarterView() {
        for view in SampleData.views {
            let draft = ViewDraft(view)
            #expect(draft.rule == view.rule, "\(view.name)")
            #expect(!draft.items.contains { if case .preserved = $0.content { true } else { false } })
        }
    }

    @Test func everyOperatorRoundTrips() {
        let rows: [RuleRowDraft] = [
            RuleRowDraft(field: .author, op: .is, includesMe: true),
            RuleRowDraft(field: .author, op: .isNot, values: ["apark"]),
            RuleRowDraft(field: .author, op: .isAnyOf, values: ["apark", "jlin-agent"]),
            RuleRowDraft(field: .assignee, op: .is, includesMe: true),
            RuleRowDraft(field: .assignee, op: .isAnyOf, includesMe: true, values: ["apark"]),
            RuleRowDraft(field: .assignee, op: .isNot, values: ["apark"]),
            RuleRowDraft(field: .assignee, op: .isEmpty),
            RuleRowDraft(field: .assignee, op: .isNotEmpty),
            RuleRowDraft(field: .reviewRequested, op: .fromMe),
            RuleRowDraft(field: .reviewRequested, op: .fromMeOrMyTeams),
            RuleRowDraft(field: .reviewRequested, op: .isAnyOf, values: ["apark", "acme/platform"]),
            RuleRowDraft(field: .repo, op: .is, values: ["acme/web"]),
            RuleRowDraft(field: .repo, op: .isAnyOf, values: ["acme/web", "acme/api"]),
            RuleRowDraft(field: .repo, op: .isNot, values: ["acme/docs"]),
            RuleRowDraft(field: .label, op: .has, values: ["qa"]),
            RuleRowDraft(field: .label, op: .doesNotHave, values: ["wip"]),
            RuleRowDraft(field: .draft, values: ["yes"]),
            RuleRowDraft(field: .draft, values: ["no"]),
            RuleRowDraft(field: .ci, op: .is, values: ["running", "failed"]),
            RuleRowDraft(field: .ci, op: .isNot, values: ["noChecks"]),
            RuleRowDraft(field: .mergeState, op: .is, values: ["clean", "inQueue"]),
            RuleRowDraft(field: .mergeState, op: .isNot, values: ["conflicts"]),
            RuleRowDraft(field: .lane, op: .is, values: ["yourMove"]),
            RuleRowDraft(field: .lane, op: .isNot, values: ["waiting"]),
            RuleRowDraft(field: .title, op: .contains, text: "deps"),
            RuleRowDraft(field: .title, op: .doesNotContain, text: "wip"),
            RuleRowDraft(field: .baseBranch, op: .is, values: ["main"]),
            RuleRowDraft(field: .baseBranch, op: .isAnyOf, values: ["main", "release"]),
            RuleRowDraft(field: .baseBranch, op: .isNot, values: ["main"]),
        ]
        for row in rows {
            let predicate = try! #require(row.predicate, "\(row.field) \(row.op)")
            let back = try! #require(RuleRowDraft(predicate: predicate), "\(predicate)")
            #expect(back.field == row.field)
            #expect(back.op == row.op, "\(row.field) \(row.op) came back as \(back.op)")
            #expect(back.predicate == predicate)
        }
    }

    @Test func operatorsMapToTheRightPredicates() {
        #expect(RuleRowDraft(field: .assignee, op: .isEmpty).predicate == .unassigned)
        #expect(RuleRowDraft(field: .assignee, op: .isNotEmpty).predicate == .not(.unassigned))
        #expect(RuleRowDraft(field: .label, op: .doesNotHave, values: ["wip"]).predicate == .not(.label(["wip"])))
        #expect(RuleRowDraft(field: .reviewRequested, op: .fromMeOrMyTeams).predicate == .reviewRequested(.meOrMyTeams))
        #expect(RuleRowDraft(field: .draft, values: ["no"]).predicate == .isDraft(false))
        #expect(RuleRowDraft(field: .title, op: .contains, text: "  deps ").predicate == .titleContains("deps"))
        #expect(RuleRowDraft(field: .author, op: .isNot, includesMe: true).predicate == .not(.author(.me)))
    }

    @Test func nestedGroupRoundTrips() {
        let rule = FilterRule(match: .all, [
            .group(FilterRule(match: .any, [.predicate(.author(.me)), .predicate(.assignee(.me))])),
            .predicate(.isDraft(false)),
        ])
        let draft = ViewDraft(SavedView(name: "Mine", rule: rule))
        guard case .group(let group) = draft.items[0].content else { Issue.record("expected a group"); return }
        #expect(group.match == .any)
        #expect(group.rows.count == 2)
        #expect(draft.rule == rule)
    }

    @Test func deeperNestingIsPreservedAsIs() {
        let deep = FilterCondition.group(FilterRule(match: .any, [.group(FilterRule(match: .all, [.predicate(.author(.me))]))]))
        let doubleNot = FilterCondition.predicate(.not(.not(.author(.me))))
        let rule = FilterRule(match: .all, [deep, doubleNot, .predicate(.repo(["acme/web"]))])
        let draft = ViewDraft(SavedView(name: "Deep", rule: rule))
        #expect(draft.rule == rule)
        #expect(draft.isValid)
        if case .preserved = draft.items[0].content {} else { Issue.record("expected the deep group to be preserved") }
        if case .preserved = draft.items[1].content {} else { Issue.record("expected not-not to be preserved") }
    }

    @Test func validation() {
        var draft = ViewDraft(name: "  ", items: [])
        #expect(draft.issues.map(\.kind) == [.nameMissing, .noRules])
        #expect(draft.savedView == nil)

        draft.name = "Watchlist"
        let rowID = draft.addRow(field: .author)
        #expect(draft.issues.map(\.kind) == [.emptyValue])
        #expect(draft.issues.first?.rowID == rowID)

        var row = draft.row(rowID)!
        row.addTokens(["tbrandt"])
        draft.update(row)
        #expect(draft.isValid)

        let groupRow = draft.addGroup()
        #expect(draft.issues.map(\.kind) == [.emptyValue])
        #expect(draft.issues.first?.rowID == groupRow)

        draft.remove(groupRow)  // the group goes with its last row
        #expect(draft.items.count == 1)
        #expect(draft.isValid)

        let title = draft.addRow(field: .title)
        #expect(draft.issues.first?.rowID == title)
        var t = draft.row(title)!
        t.text = "  "
        draft.update(t)
        #expect(!draft.isValid)
        draft.remove(title)

        let ci = draft.addRow(field: .ci)
        #expect(draft.issues.first?.rowID == ci)
        draft.remove(ci)

        // Operators that need no value are valid as they are.
        draft.addRow(field: .reviewRequested)
        #expect(draft.isValid)
        #expect(draft.savedView?.name == "Watchlist")
    }

    @Test func emptyGroupIsAnIssue() {
        var draft = ViewDraft(name: "X", items: [.group(RuleGroupDraft(match: .any, rows: []))])
        #expect(draft.issues.map(\.kind) == [.emptyGroup])
        draft.items.append(.row(RuleRowDraft(field: .reviewRequested)))
        #expect(draft.issues.map(\.kind) == [.emptyGroup])
    }

    @Test func previewRuleSkipsUnfinishedRows() {
        var draft = ViewTemplate.watchlist.draft()
        #expect(draft.rule == FilterRule(match: .all, [.predicate(.isDraft(false))]))
        var row = draft.row(draft.firstEmptyPeopleRowID!)!
        row.addTokens(TokenInput.split("@tbrandt, nhaddad"))
        draft.update(row)
        #expect(draft.rule == BuiltInViews.watchlist(["tbrandt", "nhaddad"]).rule)
    }

    @Test func tokensFromPaste() {
        #expect(TokenInput.split("@rchen, jlin-agent apark\ntbrandt;nhaddad,,") == ["rchen", "jlin-agent", "apark", "tbrandt", "nhaddad"])
        #expect(TokenInput.endsWithSeparator("apark,"))
        #expect(TokenInput.endsWithSeparator("apark "))
        #expect(!TokenInput.endsWithSeparator("apark"))
    }

    @Test func addingTokens() {
        var row = RuleRowDraft(field: .author, op: .is)
        #expect(row.addTokens(["me", "apark", "APARK", "@x".replacingOccurrences(of: "@", with: "")]) == 3)
        #expect(row.includesMe)
        #expect(row.values == ["apark", "x"])
        #expect(row.op == .isAnyOf)  // "is" with several becomes "is any of"
        row.removeLastToken()
        row.removeLastToken()
        #expect(row.values.isEmpty && row.includesMe)
        row.removeLastToken()
        #expect(row.isMissingValue)

        var repo = RuleRowDraft(field: .repo)
        repo.addTokens(["me"])
        #expect(repo.values == ["me"])  // "me" is only special for people
    }

    @Test func changingFieldKeepsWhatFits() {
        var row = RuleRowDraft(field: .author, op: .isNot, values: ["apark"])
        row.setField(.assignee)
        #expect(row.op == .isNot)
        #expect(row.values == ["apark"])
        row.setField(.label)
        #expect(row.op == .has)
        #expect(row.values.isEmpty)
        row.setField(.draft)
        #expect(row.values == ["no"])
        row.setField(.ci)
        #expect(row.values.isEmpty)
        row.toggleChoice("failed")
        row.toggleChoice("running")
        row.toggleChoice("failed")
        #expect(row.values == ["running"])
    }

    @Test func templates() {
        let watch = ViewTemplate.watchlist.draft(existingNames: ["Watchlist"])
        #expect(watch.name == "Watchlist 2")
        #expect(watch.notify == [.newMatch])
        #expect(watch.firstEmptyPeopleRowID != nil)
        #expect(ViewTemplate.watchlist.needsLogins && ViewTemplate.agentPRs.needsLogins)
        #expect(!ViewTemplate.mine.needsLogins)

        let mine = ViewTemplate.mine.draft()
        #expect(mine.rule == BuiltInViews.mine.rule)
        #expect(mine.id != BuiltInViews.mineID)
        #expect(mine.isValid)

        let review = ViewTemplate.needsMyReview.draft()
        #expect(review.rule == FilterRule(match: .all, [.predicate(.reviewRequested(.meOrMyTeams))]))
        #expect(review.usesTeams)
        #expect(review.notify == [.reviewRequested])

        let agents = ViewTemplate.agentPRs.draft()
        #expect(agents.notify.contains(.ciFailed))
        #expect(!agents.isValid)  // needs logins first

        let blank = ViewTemplate.blank.draft()
        #expect(blank.name.isEmpty)
        #expect(blank.items.count == 1)
        #expect(blank.issues.map(\.kind) == [.nameMissing, .emptyValue])
    }

    @Test func ciOutcomeSummary() {
        #expect(CIOutcomeChoice.summary(Set(CIOutcomeChoice.kinds)) == "Any outcome")
        #expect(CIOutcomeChoice.summary([.ciFailed]) == "Failed")
        #expect(CIOutcomeChoice.summary([.newMatch]) == "Off")
        #expect(CIOutcomeChoice.summary([.ciFailed, .ciReady, .newMatch]) == "Failed, Ready")
    }
}

@Suite struct SavedViewCompatibilityTests {
    /// `views.json` exactly as the first release (main at 047da9e) wrote it: the four
    /// starter views plus one with a nested none/any group using every predicate it had.
    static let firstReleaseJSON = #"""
[{"id":"00000000-0000-0000-0000-000000000001","name":"Mine","notify":["ciBlocked","droppedFromMergeQueue","changesRequested","approved","ciReady","ciFailed"],"pinnedToMenubar":true,"rule":{"conditions":[{"predicate":{"_0":{"author":{"_0":{"includesMe":true,"logins":[]}}}}},{"predicate":{"_0":{"assignee":{"_0":{"includesMe":true,"logins":[]}}}}}],"match":"any"},"symbol":"tray"},{"id":"00000000-0000-0000-0000-000000000002","name":"Needs my review","notify":["reviewRequested"],"pinnedToMenubar":true,"rule":{"conditions":[{"predicate":{"_0":{"reviewRequested":{"_0":{"includesMe":true,"logins":[]}}}}}],"match":"all"},"symbol":"eye"},{"id":"00000000-0000-0000-0000-000000000004","name":"Agent PRs","notify":["droppedFromMergeQueue","ciFailed","ciBlocked","ciReady"],"pinnedToMenubar":false,"rule":{"conditions":[{"predicate":{"_0":{"author":{"_0":{"includesMe":false,"logins":["jlin-agent"]}}}}},{"predicate":{"_0":{"assignee":{"_0":{"includesMe":true,"logins":[]}}}}}],"match":"all"},"symbol":"sparkles"},{"id":"00000000-0000-0000-0000-000000000003","name":"Watchlist","notify":["newMatch"],"pinnedToMenubar":false,"rule":{"conditions":[{"predicate":{"_0":{"author":{"_0":{"includesMe":false,"logins":["tbrandt","nhaddad"]}}}}},{"predicate":{"_0":{"isDraft":{"_0":false}}}}],"match":"all"},"symbol":"person.2"},{"id":"00000000-0000-0000-0000-0000000000AA","name":"Everything","notify":["newMatch","ciFailed"],"pinnedToMenubar":false,"rule":{"conditions":[{"group":{"_0":{"conditions":[{"predicate":{"_0":{"repo":{"_0":["acme\/web"]}}}},{"predicate":{"_0":{"label":{"_0":["wip"]}}}},{"predicate":{"_0":{"ci":{"_0":["failed","noChecks"]}}}},{"predicate":{"_0":{"mergeState":{"_0":["inQueue","autoMerge"]}}}},{"predicate":{"_0":{"reviewRequested":{"_0":{"includesMe":true,"logins":[]}}}}}],"match":"any"}}}],"match":"none"},"symbol":"line.3.horizontal.decrease.circle"}]
"""#

    @Test func viewsWrittenByTheFirstReleaseStillLoad() throws {
        let views = try JSONDecoder().decode([SavedView].self, from: Data(Self.firstReleaseJSON.utf8))
        #expect(views.count == 5)
        #expect(views[0] == BuiltInViews.mine)
        #expect(views[1] == BuiltInViews.needsMyReview)
        #expect(views[2] == BuiltInViews.agentPRs(["jlin-agent"]))
        #expect(views[3] == BuiltInViews.watchlist(["tbrandt", "nhaddad"]))
        guard case .group(let inner) = views[4].rule.conditions.first else { Issue.record("expected a group"); return }
        #expect(views[4].rule.match == .none)
        #expect(inner.conditions.count == 5)
        #expect(inner.conditions.last == .predicate(.reviewRequested(.me)))
        // And it still opens in the editor.
        #expect(ViewDraft(views[4]).rule == views[4].rule)
    }

    @Test func loadsThroughTheFileStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("views.json")
        try Data(Self.firstReleaseJSON.utf8).write(to: file)
        let views = try JSONFileStore<[SavedView]>(url: file).load()
        #expect(views?.count == 5)
    }

    @Test func viewsWithoutNewFeaturesEncodeAsBefore() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try JSONDecoder().decode([SavedView].self, from: Data(Self.firstReleaseJSON.utf8))
        let again = try JSONDecoder().decode([SavedView].self, from: try encoder.encode(original))
        #expect(again == original)
        // A "me" list doesn't gain an includesMyTeams key, so older builds read it the same.
        let me = String(decoding: try encoder.encode(UserList.me), as: UTF8.self)
        #expect(me == #"{"includesMe":true,"logins":[]}"#)
    }

    @Test func newPredicatesRoundTrip() throws {
        let rule = FilterRule(match: .all, [
            .predicate(.not(.label(["wip"]))), .predicate(.unassigned), .predicate(.titleContains("deps")),
            .predicate(.baseBranch(["main"])), .predicate(.lane([.yourMove])), .predicate(.reviewRequested(.meOrMyTeams)),
        ])
        let view = SavedView(name: "New", rule: rule, notify: [.newMatch])
        let back = try JSONDecoder().decode(SavedView.self, from: JSONEncoder().encode(view))
        #expect(back == view)
    }
}
