import Foundation
import Testing
@testable import GitHubPRWatchCore

@Suite struct FilterTests {
    @Test func userPredicatesResolveMe() {
        #expect(Predicate.author(.me).evaluate(pr(author: me), viewer: me) == true)
        #expect(Predicate.author(.me).evaluate(pr(author: "apark"), viewer: me) == false)
        #expect(Predicate.author(.anyOf(["apark", "jlin-agent"])).evaluate(pr(author: "JLin-Agent"), viewer: me) == true)
        #expect(Predicate.author(.me).evaluate(pr(author: nil), viewer: me) == false)
        #expect(Predicate.assignee(.me).evaluate(pr(assignees: ["x", me]), viewer: me) == true)
        #expect(Predicate.reviewRequested(.me).evaluate(pr(reviewRequests: [.user(me)]), viewer: me) == true)
        #expect(Predicate.reviewRequested(.me).evaluate(pr(reviewRequests: [.team("acme/rchen")]), viewer: me) == false)
        #expect(Predicate.author(UserList(includesMe: true, logins: ["apark"])).evaluate(pr(author: "apark"), viewer: me) == true)
    }

    @Test func emptyLoginListMatchesNobody() {
        #expect(Predicate.author(.anyOf([])).evaluate(pr(), viewer: me) == false)
    }

    @Test func repoLabelDraft() {
        #expect(Predicate.repo(["ACME/web"]).evaluate(pr(repo: "acme/web"), viewer: me) == true)
        #expect(Predicate.repo(["acme/api"]).evaluate(pr(repo: "acme/web"), viewer: me) == false)
        #expect(Predicate.label(["needs-qa"]).evaluate(pr(labels: ["Needs-QA"]), viewer: me) == true)
        #expect(Predicate.label(["needs-qa"]).evaluate(pr(labels: []), viewer: me) == false)
        #expect(Predicate.isDraft(false).evaluate(pr(draft: true), viewer: me) == false)
        #expect(Predicate.isDraft(true).evaluate(pr(draft: true), viewer: me) == true)
    }

    @Test func ciStateIsUnknownWithoutDetail() {
        #expect(Predicate.ci([.failed]).evaluate(pr(), viewer: me) == nil)
        #expect(Predicate.ci([.failed]).evaluate(pr(checks: [check("a", .failed)]), viewer: me) == true)
        #expect(Predicate.ci([.running]).evaluate(pr(checks: [check("a", .running)]), viewer: me) == true)
        #expect(Predicate.ci([.passed]).evaluate(pr(checks: [check("a")]), viewer: me) == true)
        #expect(Predicate.ci([.noChecks]).evaluate(pr(checks: []), viewer: me) == true)
        #expect(Predicate.ci([.passed]).evaluate(pr(checks: [check("a")], checksHead: "old"), viewer: me) == nil)
    }

    @Test func mergeStates() {
        #expect(Predicate.mergeState([.inQueue]).evaluate(pr(queue: MergeQueueEntry(position: 0)), viewer: me) == true)
        #expect(Predicate.mergeState([.conflicts]).evaluate(pr(mergeable: .conflicting), viewer: me) == true)
        #expect(Predicate.mergeState([.behind]).evaluate(pr(state: .behind), viewer: me) == true)
        #expect(Predicate.mergeState([.blocked, .behind]).evaluate(pr(state: .clean), viewer: me) == false)
        #expect(Predicate.mergeState([.clean]).evaluate(pr(state: .hasHooks), viewer: me) == true)
        #expect(Predicate.mergeState([.autoMerge]).evaluate(pr(autoMerge: true), viewer: me) == true)
    }

    @Test func threeValuedGroups() {
        let unknown = FilterCondition.predicate(.ci([.failed]))
        let yes = FilterCondition.predicate(.author(.me))
        let no = FilterCondition.predicate(.isDraft(true))
        let p = pr()
        #expect(FilterRule(match: .all, [yes, unknown]).evaluate(p, viewer: me) == nil)
        #expect(FilterRule(match: .all, [no, unknown]).evaluate(p, viewer: me) == false)
        #expect(FilterRule(match: .any, [yes, unknown]).evaluate(p, viewer: me) == true)
        #expect(FilterRule(match: .any, [no, unknown]).evaluate(p, viewer: me) == nil)
        #expect(FilterRule(match: .none, [no]).evaluate(p, viewer: me) == true)
        #expect(FilterRule(match: .none, [yes]).evaluate(p, viewer: me) == false)
        #expect(FilterRule(match: .none, [no, unknown]).evaluate(p, viewer: me) == nil)
        #expect(FilterRule(match: .all, []).evaluate(p, viewer: me) == true)
        #expect(FilterRule(match: .any, []).evaluate(p, viewer: me) == false)

        let rule = FilterRule(match: .all, [yes, unknown])
        #expect(rule.mightMatch(p, viewer: me))
        #expect(!rule.matches(p, viewer: me))
    }

    @Test func nestedGroups() {
        // Mine, but not in acme/api: author me AND none of (repo acme/api).
        let rule = FilterRule(match: .all, [
            .predicate(.author(.me)),
            .group(FilterRule(match: .none, [.predicate(.repo(["acme/api"]))])),
        ])
        #expect(rule.matches(pr(repo: "acme/web"), viewer: me))
        #expect(!rule.matches(pr(repo: "acme/api"), viewer: me))
    }

    @Test func builtInViews() {
        let mine = BuiltInViews.mine
        #expect(mine.matches(pr(author: me), viewer: me))
        #expect(mine.matches(pr(author: "jlin-agent", assignees: [me]), viewer: me))
        #expect(!mine.matches(pr(author: "apark"), viewer: me))

        let review = BuiltInViews.needsMyReview
        #expect(review.matches(pr(author: "apark", reviewRequests: [.user(me)]), viewer: me))
        #expect(!review.matches(pr(author: "apark"), viewer: me))

        let watch = BuiltInViews.watchlist(["tbrandt", "nhaddad"])
        #expect(watch.matches(pr(author: "tbrandt"), viewer: me))
        #expect(!watch.matches(pr(author: "tbrandt", draft: true), viewer: me))
        #expect(!watch.matches(pr(author: "apark"), viewer: me))

        let agents = BuiltInViews.agentPRs(["jlin-agent"])
        #expect(agents.matches(pr(author: "jlin-agent", assignees: [me]), viewer: me))
        #expect(!agents.matches(pr(author: "jlin-agent"), viewer: me))
        #expect(!agents.matches(pr(author: me, assignees: [me]), viewer: me))

        #expect(BuiltInViews.all.map(\.name) == ["Mine", "Needs my review", "Agent PRs", "Watchlist"])
        #expect(Set(BuiltInViews.all.map(\.id)).count == 4)
    }

    @Test func summaries() {
        #expect(BuiltInViews.mine.rule.summary == "author is me, or assignee is me")
        #expect(BuiltInViews.agentPRs(["jlin-agent"]).rule.summary == "author is jlin-agent, and assignee is me")
    }

    @Test func viewsRoundTripThroughJSON() throws {
        let views = BuiltInViews.all + [SavedView(
            name: "Custom",
            rule: FilterRule(match: .any, [
                .predicate(.ci([.failed, .running])),
                .predicate(.mergeState([.inQueue])),
                .group(FilterRule(match: .none, [.predicate(.label(["wip"]))])),
            ]),
            notify: [.ciFailed, .newMatch]
        )]
        let data = try JSONCoding.encoder.encode(views)
        let decoded = try JSONCoding.decoder.decode([SavedView].self, from: data)
        #expect(decoded == views)
    }

    @Test func jsonFileStorePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<[SavedView]>(url: dir.appendingPathComponent("nested/views.json"))
        #expect(try store.load() == nil)
        try store.save(BuiltInViews.defaults)
        #expect(try store.load() == BuiltInViews.defaults)
        // A second store at the same path, as after a relaunch.
        #expect(try JSONFileStore<[SavedView]>(url: store.url).load() == BuiltInViews.defaults)
    }

    @Test func inMemoryStore() throws {
        let store = InMemoryDocumentStore<AppConfig>()
        #expect(try store.load() == nil)
        try store.save(AppConfig(watchedRepos: ["acme/web"]))
        #expect(try store.load()?.watchedRepos == ["acme/web"])
        #expect(store.saveCount == 1)
    }
}
