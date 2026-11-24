import Foundation
@testable import GitHubPRWatchCore

let me = "rchen"
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func minutes(_ m: Double, after date: Date = t0) -> Date { date.addingTimeInterval(m * 60) }

func check(
    _ name: String, _ state: CheckFixture = .passed, start: Double = -30, end: Double = -1, required: Bool = false
) -> CheckRun {
    switch state {
    case .running:
        CheckRun(name: name, status: .inProgress, startedAt: minutes(start), isRequired: required)
    case .passed:
        CheckRun(name: name, status: .completed, conclusion: .success, startedAt: minutes(start), completedAt: minutes(end), isRequired: required)
    case .failed:
        CheckRun(name: name, status: .completed, conclusion: .failure, startedAt: minutes(start), completedAt: minutes(end), isRequired: required)
    }
}

enum CheckFixture { case running, passed, failed }

/// A PR with sensible defaults: authored by the viewer, approved, clean, on head "h1".
func pr(
    _ id: String = "PR_1",
    repo: String = "acme/web",
    number: Int = 1,
    author: String? = me,
    assignees: [String] = [],
    reviewRequests: [ReviewRequest] = [],
    latestReviews: [Review] = [],
    labels: [String] = [],
    draft: Bool = false,
    decision: ReviewDecision? = .approved,
    mergeable: Mergeable = .mergeable,
    state: MergeStateStatus = .clean,
    autoMerge: Bool = false,
    queue: MergeQueueEntry? = nil,
    head: String = "h1",
    checks: [CheckRun]? = nil,
    checksHead: String? = nil,
    removal: MergeQueueRemoval? = nil
) -> PullRequest {
    PullRequest(
        id: id, repo: repo, number: number, title: "Title \(number)", isDraft: draft, author: author,
        assignees: assignees, reviewRequests: reviewRequests, latestReviews: latestReviews, labels: labels,
        reviewDecision: decision, mergeable: mergeable, mergeStateStatus: state, autoMergeEnabled: autoMerge,
        mergeQueueEntry: queue, headSHA: head, baseRef: "main", createdAt: minutes(-120), updatedAt: minutes(-10),
        checks: checks.map { CheckSummary(headSHA: checksHead ?? head, rollup: nil, checks: $0, lastQueueRemoval: removal) }
    )
}

/// Answers requests from a handler. Records each request body.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int) throws -> (Int, [String: String], String)
    private let lock = NSLock()
    private(set) var bodies: [String] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Replies with the same JSON every time.
    convenience init(status: Int = 200, headers: [String: String] = [:], json: String) {
        self.init { _, _ in (status, headers, json) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let index: Int = lock.withLock {
            bodies.append(body)
            return bodies.count - 1
        }
        let (status, headers, json) = try handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(json.utf8), response)
    }
}
