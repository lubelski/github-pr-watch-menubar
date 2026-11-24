import Foundation

/// How long to wait before the next poll.
public struct PollPolicy: Sendable, Equatable {
    public static let defaultInterval: TimeInterval = 60

    public var baseInterval: TimeInterval
    /// Below this share of the hourly budget, polls spread out so the budget lasts until reset.
    public var lowBudgetFraction: Double
    public var maxInterval: TimeInterval

    public init(baseInterval: TimeInterval = defaultInterval, lowBudgetFraction: Double = 0.2, maxInterval: TimeInterval = 15 * 60) {
        self.baseInterval = baseInterval
        self.lowBudgetFraction = lowBudgetFraction
        self.maxInterval = maxInterval
    }

    /// The delay after a successful poll that cost `pollCost` points.
    public func interval(after rateLimit: RateLimit?, pollCost: Int, now: Date) -> TimeInterval {
        guard let rateLimit, rateLimit.limit > 0 else { return baseInterval }
        let untilReset = max(0, rateLimit.resetAt.timeIntervalSince(now))
        if rateLimit.remaining <= 0 { return max(baseInterval, untilReset + 5) }
        guard Double(rateLimit.remaining) < Double(rateLimit.limit) * lowBudgetFraction else { return baseInterval }
        // Spread the remaining polls evenly over the time left, keeping a fifth in reserve.
        let pollsLeft = Double(rateLimit.remaining) * 0.8 / Double(max(pollCost, 1))
        guard pollsLeft >= 1 else { return min(maxInterval, max(baseInterval, untilReset + 5)) }
        return min(maxInterval, max(baseInterval, untilReset / pollsLeft))
    }

    /// The delay after a failed poll. `attempt` counts consecutive failures from 1.
    /// `nil` means stop polling until the user acts (the token was rejected).
    public func interval(after error: GitHubError, attempt: Int, now: Date) -> TimeInterval? {
        let backoff = { (start: TimeInterval) in min(self.maxInterval, start * pow(2, Double(max(0, attempt - 1)))) }
        switch error {
        case .unauthorized, .auth:
            return nil
        case .rateLimited(let resetAt):
            return max(baseInterval, (resetAt?.timeIntervalSince(now) ?? 15 * 60) + 5)
        case .secondaryRateLimit(let retryAfter):
            return max(retryAfter ?? backoff(120), 60)
        case .offline:
            return backoff(30)
        case .http, .graphQL, .decoding:
            return max(baseInterval, backoff(60))
        }
    }
}
