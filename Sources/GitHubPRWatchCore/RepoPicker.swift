import Foundation

/// Search and suggestions for the onboarding repo picker.
public enum RepoPicker {
    /// Repos whose `owner/name` contains every word of `query`, case-insensitively, in the
    /// original order (most recently pushed first).
    public static func filter(_ repos: [Repo], query: String) -> [Repo] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return repos }
        return repos.filter { repo in
            let name = repo.nameWithOwner.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// Repos grouped by owner, owners in order of their most recent push, the viewer's own last.
    public static func grouped(_ repos: [Repo], viewer: String?) -> [(owner: String, repos: [Repo])] {
        var order: [String] = []
        var groups: [String: [Repo]] = [:]
        for repo in repos {
            if groups[repo.owner] == nil { order.append(repo.owner) }
            groups[repo.owner, default: []].append(repo)
        }
        if let viewer, let index = order.firstIndex(where: { $0.caseInsensitiveCompare(viewer) == .orderedSame }) {
            order.append(order.remove(at: index))
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// Repos to pre-check: up to `limit` non-fork repos owned by someone other than the
    /// viewer (team repos are where PRs pile up), pushed within `recentDays`. Repos with a
    /// merge queue come first.
    public static func suggested(_ repos: [Repo], viewer: String, now: Date, limit: Int = 3, recentDays: Double = 30) -> [String] {
        let cutoff = now.addingTimeInterval(-recentDays * 86_400)
        let candidates = repos.filter {
            !$0.isFork && $0.owner.caseInsensitiveCompare(viewer) != .orderedSame && ($0.pushedAt ?? .distantPast) >= cutoff
        }
        let ranked = candidates.filter(\.hasMergeQueue) + candidates.filter { !$0.hasMergeQueue }
        return ranked.prefix(limit).map(\.nameWithOwner)
    }
}
