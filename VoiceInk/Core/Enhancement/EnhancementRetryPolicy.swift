import Foundation

/// Decides whether a failed enhancement request gets another attempt.
enum EnhancementRetryPolicy {
    enum Failure {
        case networkError
        case serverError
        case rateLimitExceeded
        case timeout
        case other
    }

    enum Decision: Equatable {
        case retry(after: TimeInterval)
        case switchToFallback
        case fail
    }

    /// - Parameters:
    ///   - failedAttempts: Requests sent so far, including the one that just failed.
    ///   - fallbackAvailable: Whether another provider can still take over this enhancement.
    static func decision(
        for failure: Failure,
        failedAttempts: Int,
        maxAttempts: Int,
        retryOnTimeout: Bool,
        fallbackAvailable: Bool = false,
        initialDelay: TimeInterval = 1.0
    ) -> Decision {
        guard failedAttempts < maxAttempts else { return .fail }

        if fallbackAvailable {
            switch failure {
            case .rateLimitExceeded, .serverError:
                // The provider refused or broke; another provider answers without a backoff delay.
                return .switchToFallback
            case .timeout where retryOnTimeout:
                return .switchToFallback
            case .networkError, .timeout, .other:
                // A local network problem or a bad request would fail on the fallback as well.
                break
            }
        }

        switch failure {
        case .networkError, .serverError:
            return .retry(after: initialDelay * pow(2, Double(failedAttempts - 1)))
        case .rateLimitExceeded:
            // A 429 means the provider's per-minute or per-day quota is used up. Retrying after
            // one or two seconds almost never succeeds, keeps the recorder on "Enhancing" and
            // spends more of the same quota. The raw transcript is delivered instead.
            return .fail
        case .timeout:
            return retryOnTimeout ? .retry(after: 0) : .fail
        case .other:
            return .fail
        }
    }
}
