import Foundation

/// What a draft rule matches right now.
public struct RulePreview: Sendable, Equatable {
    /// Matching PRs, in lane order, most recently updated first within a lane.
    public var matches: [ClassifiedPR]
    /// PRs that might match once their check detail arrives on the next refresh.
    public var undecided: Int
}

// Helpers for the view editor and the manage-views list. Everything here goes through
// PRStore's public API, so it adds no state.
extension PRStore {
    /// The PRs a rule matches now, without saving it. No network.
    public func preview(_ rule: FilterRule) -> RulePreview {
        guard let context = filterContext else { return RulePreview(matches: [], undecided: 0) }
        var matches: [ClassifiedPR] = []
        var undecided = 0
        for item in pullRequests {
            switch rule.evaluate(item.pr, in: context) {
            case true?: matches.append(item)
            case nil: undecided += 1
            case false?: break
            }
        }
        return RulePreview(matches: Self.lanes(matches).flatMap(\.pullRequests), undecided: undecided)
    }

    /// Logins seen on the current PRs (authors, assignees, requested and past reviewers),
    /// most frequent first, without the viewer (who is "me").
    public var knownLogins: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        func add(_ login: String?) {
            guard let login, !login.isEmpty else { return }
            let key = login.lowercased()
            counts[key, default: (login, 0)].count += 1
        }
        for item in pullRequests {
            let pr = item.pr
            add(pr.author)
            pr.assignees.forEach(add)
            pr.reviewRequests.compactMap(\.userLogin).forEach(add)
            pr.latestReviews.map(\.author).forEach(add)
        }
        if let me = viewer?.login { counts[me.lowercased()] = nil }
        return Self.ranked(counts)
    }

    /// Teams seen in review requests and the viewer's own teams, as `org/slug`.
    public var knownTeams: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for item in pullRequests {
            for case .team(let team) in item.pr.reviewRequests { counts[team.lowercased(), default: (team, 0)].count += 1 }
        }
        for team in viewerTeams { counts[team, default: (team, 0)].count += 1 }
        return Self.ranked(counts)
    }

    /// Watched repos first, then any other repo a PR came from.
    public var knownRepos: [String] {
        var seen = Set<String>()
        return (watchedRepos + pullRequests.map(\.pr.repo)).filter { seen.insert($0.lowercased()).inserted }
    }

    public var knownLabels: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for item in pullRequests { for label in item.pr.labels { counts[label.lowercased(), default: (label, 0)].count += 1 } }
        return Self.ranked(counts)
    }

    public var knownBaseBranches: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for item in pullRequests { counts[item.pr.baseRef, default: (item.pr.baseRef, 0)].count += 1 }
        return Self.ranked(counts)
    }

    /// Suggestions for a rule field's token input.
    public func suggestions(for field: RuleField) -> [String] {
        switch field {
        case .author, .assignee: knownLogins
        case .reviewRequested: knownLogins + knownTeams
        case .repo: knownRepos
        case .label: knownLabels
        case .baseBranch: knownBaseBranches
        default: []
        }
    }

    /// Saves a copy right after the original, named "… copy". Returns the copy.
    @discardableResult
    public func duplicateView(id: UUID) -> SavedView? {
        guard let index = views.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = views[index]
        copy.id = UUID()
        copy.name = ViewTemplate.uniqueName("\(copy.name) copy", existing: views.map(\.name))
        copy.pinnedToMenubar = false
        saveView(copy)
        moveViews(fromOffsets: IndexSet(integer: views.count - 1), toOffset: index + 1)
        return copy
    }

    private static func ranked(_ counts: [String: (name: String, count: Int)]) -> [String] {
        counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.lowercased() < $1.name.lowercased() }.map(\.name)
    }
}
