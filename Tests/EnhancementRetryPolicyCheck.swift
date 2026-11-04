import Foundation

// Compile together with EnhancementRetryPolicy.swift and EnhancementFallbackRoute.swift
// (see scripts/check-enhancement-retry.sh). Replays the retry loop of
// AIEnhancementService.makeRequestWithRetry against providers that answer the same way every
// time, and checks how many requests go out, to which provider, and how long the user waits on
// "Enhancing" before text arrives.

@main
struct EnhancementRetryPolicyCheck {
    nonisolated(unsafe) static var failures = 0

    enum Outcome {
        case success
        case failure(EnhancementRetryPolicy.Failure)
    }

    struct Run: Equatable {
        var requests: Int
        var fallbackRequests = 0
        var succeeded = false
        let waitedSeconds: TimeInterval

        static func == (lhs: Run, rhs: Run) -> Bool {
            lhs.requests == rhs.requests && lhs.fallbackRequests == rhs.fallbackRequests
                && lhs.succeeded == rhs.succeeded && abs(lhs.waitedSeconds - rhs.waitedSeconds) < 0.0001
        }
    }

    /// - Parameter fallback: How the fallback provider answers, or `nil` when none is configured.
    static func replay(
        _ primary: Outcome,
        fallback: Outcome? = nil,
        retryOnTimeout: Bool = true,
        maxAttempts: Int = 3,
        primarySeconds: TimeInterval = 0.2,
        fallbackSeconds: TimeInterval = 0.2
    ) -> Run {
        var requests = 0
        var fallbackRequests = 0
        var waited: TimeInterval = 0
        var usingFallback = false
        while true {
            let outcome: Outcome
            if usingFallback, let fallback {
                fallbackRequests += 1
                waited += fallbackSeconds
                outcome = fallback
            } else {
                waited += primarySeconds
                outcome = primary
            }
            requests += 1

            guard case .failure(let failure) = outcome else {
                return Run(requests: requests, fallbackRequests: fallbackRequests, succeeded: true, waitedSeconds: waited)
            }
            switch EnhancementRetryPolicy.decision(
                for: failure,
                failedAttempts: requests,
                maxAttempts: maxAttempts,
                retryOnTimeout: retryOnTimeout,
                fallbackAvailable: fallback != nil && !usingFallback
            ) {
            case .retry(let delay):
                waited += delay
            case .switchToFallback:
                usingFallback = true
            case .fail:
                return Run(requests: requests, fallbackRequests: fallbackRequests, succeeded: false, waitedSeconds: waited)
            }
        }
    }

    static func expect(_ name: String, _ actual: Run, _ expected: Run) {
        if actual == expected {
            print("PASS: \(name)")
        } else {
            failures += 1
            print("FAIL: \(name): expected \(expected), got \(actual)")
        }
    }

    static func expectFallback(provider: String, model: String, is expected: (provider: String, model: String)?) {
        let actual = EnhancementFallbackRoute.fallback(forProvider: provider, model: model)
        if actual?.provider == expected?.provider && actual?.model == expected?.model {
            print("PASS: fallback for \(provider) \(model)")
        } else {
            failures += 1
            print("FAIL: fallback for \(provider) \(model): expected \(String(describing: expected)), got \(String(describing: actual))")
        }
    }

    static func main() {
        // Without a fallback: a 429 means the quota is used up, so the raw transcript is delivered at once.
        expect("rate limit fails after one request", replay(.failure(.rateLimitExceeded)), Run(requests: 1, waitedSeconds: 0.2))
        expect("server error keeps 1 s / 2 s backoff", replay(.failure(.serverError)), Run(requests: 3, waitedSeconds: 0.6 + 1 + 2))
        expect("network error keeps 1 s / 2 s backoff", replay(.failure(.networkError)), Run(requests: 3, waitedSeconds: 0.6 + 1 + 2))
        expect(
            "timeout retries immediately when enabled",
            replay(.failure(.timeout), primarySeconds: 7),
            Run(requests: 3, waitedSeconds: 21)
        )
        expect(
            "timeout fails at once when retry is disabled",
            replay(.failure(.timeout), retryOnTimeout: false, primarySeconds: 7),
            Run(requests: 1, waitedSeconds: 7)
        )
        expect("other errors never retry", replay(.failure(.other)), Run(requests: 1, waitedSeconds: 0.2))

        // With a fallback provider: it takes over at once, without a backoff delay.
        expect(
            "rate limit switches to the fallback at once",
            replay(.failure(.rateLimitExceeded), fallback: .success),
            Run(requests: 2, fallbackRequests: 1, succeeded: true, waitedSeconds: 0.4)
        )
        expect(
            "server error switches to the fallback instead of waiting 1 s",
            replay(.failure(.serverError), fallback: .success),
            Run(requests: 2, fallbackRequests: 1, succeeded: true, waitedSeconds: 0.4)
        )
        expect(
            "rate limit on both providers delivers the raw transcript",
            replay(.failure(.rateLimitExceeded), fallback: .failure(.rateLimitExceeded)),
            Run(requests: 2, fallbackRequests: 1, succeeded: false, waitedSeconds: 0.4)
        )
        expect(
            "server error on the fallback keeps its backoff within three attempts",
            replay(.failure(.serverError), fallback: .failure(.serverError)),
            Run(requests: 3, fallbackRequests: 2, succeeded: false, waitedSeconds: 0.6 + 2)
        )
        expect(
            "network error retries the primary, not the fallback",
            replay(.failure(.networkError), fallback: .success),
            Run(requests: 3, waitedSeconds: 0.6 + 1 + 2)
        )
        expect(
            "timeout switches to the fallback when retries are enabled",
            replay(.failure(.timeout), fallback: .success, primarySeconds: 7),
            Run(requests: 2, fallbackRequests: 1, succeeded: true, waitedSeconds: 7.2)
        )
        expect(
            "timeout stays final when retries are disabled",
            replay(.failure(.timeout), fallback: .success, retryOnTimeout: false, primarySeconds: 7),
            Run(requests: 1, waitedSeconds: 7)
        )
        expect(
            "other errors never switch",
            replay(.failure(.other), fallback: .success),
            Run(requests: 1, waitedSeconds: 0.2)
        )

        // Which provider and model take over.
        expectFallback(provider: "Groq", model: "qwen/qwen3.8-27b", is: ("Cerebras", "qwen-3.8-27b"))
        expectFallback(provider: "Groq", model: "openai/gpt-oss-120b", is: ("Cerebras", "gpt-oss-120b"))
        expectFallback(provider: "Groq", model: "openai/gpt-oss-20b", is: nil)
        expectFallback(provider: "Cerebras", model: "qwen-3.8-27b", is: nil)
        expectFallback(provider: "OpenAI", model: "gpt-5.6-luna", is: nil)

        guard failures == 0 else {
            print("\(failures) enhancement retry scenario(s) failed")
            exit(1)
        }
        print("All enhancement retry scenarios passed")
    }
}
