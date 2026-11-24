import Foundation

/// GraphQL documents. Field names were checked against GitHub's public schema
/// (introspection and live read-only queries) in November 2026.
enum GitHubQueries {
    static let rateLimitFields = "rateLimit { limit cost remaining resetAt }"

    static let viewer = """
    query { \(rateLimitFields) viewer { login name avatarUrl } }
    """

    /// The viewer's own repos plus org and collaborator repos, most recently pushed first.
    static let repositories = """
    query($cursor: String) {
      \(rateLimitFields)
      viewer {
        repositories(first: 100, after: $cursor, isArchived: false,
                     affiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR],
                     ownerAffiliations: [OWNER, ORGANIZATION_MEMBER, COLLABORATOR],
                     orderBy: {field: PUSHED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes { nameWithOwner isPrivate isFork pushedAt url mergeQueue { id } }
        }
      }
    }
    """

    /// Step one: every open PR in one repo, without check detail. Cheap enough to run for
    /// large repos every poll.
    static let openPullRequests = """
    query($owner: String!, $name: String!, $cursor: String) {
      \(rateLimitFields)
      repository(owner: $owner, name: $name) {
        nameWithOwner
        pullRequests(states: OPEN, first: 50, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id number title url isDraft createdAt updatedAt headRefOid baseRefName
            author { login }
            assignees(first: 10) { nodes { login } }
            reviewRequests(first: 20) {
              nodes { requestedReviewer {
                __typename
                ... on User { login }
                ... on Bot { login }
                ... on Mannequin { login }
                ... on Team { slug organization { login } }
              } }
            }
            latestReviews(first: 20) { nodes { state submittedAt author { login } } }
            labels(first: 20) { nodes { name } }
            reviewDecision mergeable mergeStateStatus
            autoMergeRequest { enabledAt }
            mergeQueueEntry {
              position state enqueuedAt estimatedTimeToMerge
              mergeQueue { entries(first: 1) { totalCount } }
            }
          }
        }
      }
    }
    """

    /// The teams in one organization that `login` belongs to. `teams` needs the `read:org`
    /// scope (classic tokens) or the organization Members read permission (fine-grained
    /// tokens and GitHub Apps); without it GitHub answers with an INSUFFICIENT_SCOPES error.
    /// A login that is a user rather than an organization answers NOT_FOUND.
    static let viewerTeams = """
    query($org: String!, $login: String!, $cursor: String) {
      \(rateLimitFields)
      organization(login: $org) {
        teams(first: 100, after: $cursor, userLogins: [$login]) {
          pageInfo { hasNextPage endCursor }
          nodes { slug }
        }
      }
    }
    """

    /// How many PRs go in one check-detail query.
    static let checkBatchSize = 15

    /// Step two: check detail for the given PRs, one aliased `node` lookup each.
    /// `isRequired` needs the PR's ID as an argument, so IDs are written into the document
    /// instead of passed as variables. IDs are checked against a safe character set first.
    static func checkDetails(ids: [String]) -> String {
        var parts = [rateLimitFields]
        for (index, id) in ids.enumerated() {
            parts.append("""
            p\(index): node(id: "\(id)") { ... on PullRequest {
              id headRefOid
              commits(last: 1) { nodes { commit { oid statusCheckRollup { state
                contexts(first: 100) { nodes {
                  __typename
                  ... on CheckRun { name status conclusion startedAt completedAt detailsUrl
                    isRequired(pullRequestId: "\(id)") checkSuite { workflowRun { workflow { name } } } }
                  ... on StatusContext { context state targetUrl createdAt isRequired(pullRequestId: "\(id)") }
                } }
              } } } }
              timelineItems(last: 1, itemTypes: [REMOVED_FROM_MERGE_QUEUE_EVENT]) {
                nodes { ... on RemovedFromMergeQueueEvent { reason createdAt } }
              }
            } }
            """)
        }
        return "query {\n" + parts.joined(separator: "\n") + "\n}"
    }

    static func isSafeNodeID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_-=".unicodeScalars.contains($0)
        }
    }
}
