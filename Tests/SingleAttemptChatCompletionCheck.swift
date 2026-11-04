import Foundation
import LLMkit

/// Runs `SingleAttemptChatCompletion` against Tests/ChatCompletionStubServer.py and compares it with
/// `OpenAILLMClient.chatCompletion`, which retries 429 and 5xx on its own.
@main
struct SingleAttemptChatCompletionCheck {
    static let server = URL(string: ProcessInfo.processInfo.environment["STUB_URL"]!)!
    static let messages: [ChatMessage] = [.user("\n<TRANSCRIPT>\nhallo welt\n</TRANSCRIPT>")]
    static let systemPrompt = "Korrigiere das Transkript."
    static let extraBody: [String: Any] = ["include_reasoning": false]
    nonisolated(unsafe) static var failures = 0

    static func main() async throws {
        try await rateLimitIsSentOnce()
        try await serverErrorIsSentOnce()
        try await successSendsTheSameRequestAsLLMkit()
        try await timeoutIsReportedAsTimeout()
        await refusedConnectionIsANetworkError()
        try await missingKeySendsNothing()
        try await truncatedOutputIsRejected()
        try await emptyChoicesAreRejected()

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("All single-attempt chat completion checks passed")
    }

    static func rateLimitIsSentOnce() async throws {
        let llmkitStart = Date()
        do {
            _ = try await OpenAILLMClient.chatCompletion(
                baseURL: server.appending(path: "429-llmkit"), apiKey: "test-key", model: "qwen/qwen3.8-27b",
                messages: messages, systemPrompt: systemPrompt, timeout: 5)
        } catch {}
        let llmkitSeconds = Date().timeIntervalSince(llmkitStart)
        let llmkitRequests = try await stats().counts["429-llmkit"] ?? 0
        print("LLMkit on 429: \(llmkitRequests) requests in \(String(format: "%.1f", llmkitSeconds)) s")

        let start = Date()
        do {
            _ = try await complete(path: "429-single")
            expect(false, "429 should throw")
        } catch LLMKitError.httpError(let status, let message) {
            expect(status == 429, "429 keeps its status code, got \(status)")
            expect(message.contains("rate_limit_exceeded"), "429 keeps the provider message")
        }
        let seconds = Date().timeIntervalSince(start)
        let requests = try await stats().counts["429-single"] ?? 0
        print("Single attempt on 429: \(requests) request in \(String(format: "%.2f", seconds)) s")
        expect(requests == 1, "429 sends exactly one request, sent \(requests)")
        expect(seconds < 0.5, "429 returns without waiting, took \(seconds) s")
    }

    static func serverErrorIsSentOnce() async throws {
        do {
            _ = try await complete(path: "500-single")
            expect(false, "500 should throw")
        } catch LLMKitError.httpError(let status, _) {
            expect(status == 500, "500 keeps its status code, got \(status)")
        }
        let requests = try await stats().counts["500-single"] ?? 0
        expect(requests == 1, "500 sends exactly one request, sent \(requests)")
    }

    static func successSendsTheSameRequestAsLLMkit() async throws {
        let llmkitText = try await OpenAILLMClient.chatCompletion(
            baseURL: server.appending(path: "ok-llmkit"), apiKey: "test-key", model: "qwen/qwen3.8-27b",
            messages: messages, systemPrompt: systemPrompt, temperature: 0.3,
            reasoningEffort: "none", extraBody: extraBody, timeout: 5)
        let text = try await complete(path: "ok-single")
        expect(text == llmkitText && text == "Hallo Welt.", "returns the completion text, got \(text)")

        let current = try await stats()
        let sameBody = (current.bodies["ok-single"] as? NSDictionary)?.isEqual(current.bodies["ok-llmkit"]) == true
        expect(sameBody, "request body matches LLMkit: \(current.bodies["ok-single"] ?? "nil")")
        let sameHeaders = (current.headers["ok-single"] as? NSDictionary)?.isEqual(current.headers["ok-llmkit"]) == true
        expect(sameHeaders, "Authorization and Content-Type match LLMkit")
    }

    static func timeoutIsReportedAsTimeout() async throws {
        do {
            _ = try await complete(path: "slow-single", timeout: 0.5)
            expect(false, "slow response should time out")
        } catch LLMKitError.timeout {
        }
        let requests = try await stats().counts["slow-single"] ?? 0
        expect(requests == 1, "timeout sends exactly one request, sent \(requests)")
    }

    static func refusedConnectionIsANetworkError() async {
        do {
            _ = try await SingleAttemptChatCompletion.openAICompatible(
                baseURL: URL(string: "http://127.0.0.1:1/v1/chat/completions")!, apiKey: "test-key",
                model: "qwen/qwen3.8-27b", messages: messages, timeout: 2)
            expect(false, "closed port should throw")
        } catch LLMKitError.networkError {
        } catch {
            expect(false, "closed port should be a network error, got \(error)")
        }
    }

    static func missingKeySendsNothing() async throws {
        do {
            _ = try await SingleAttemptChatCompletion.openAICompatible(
                baseURL: server.appending(path: "nokey-single"), apiKey: "  ",
                model: "qwen/qwen3.8-27b", messages: messages)
            expect(false, "empty key should throw")
        } catch LLMKitError.missingAPIKey {
        }
        let requests = try await stats().counts["nokey-single"] ?? 0
        expect(requests == 0, "empty key sends no request, sent \(requests)")
    }

    static func complete(path: String, timeout: TimeInterval = 5) async throws -> String {
        try await SingleAttemptChatCompletion.openAICompatible(
            baseURL: server.appending(path: path), apiKey: "test-key", model: "qwen/qwen3.8-27b",
            messages: messages, systemPrompt: systemPrompt, temperature: 0.3,
            reasoningEffort: "none", extraBody: extraBody, timeout: timeout)
    }

    static func truncatedOutputIsRejected() async throws {
        do {
            _ = try await complete(path: "truncated-single")
            expect(false, "token-limited output must not be delivered as complete")
        } catch SingleAttemptChatCompletion.ResponseError.outputTruncated {
        }
        expect(try await stats().counts["truncated-single"] == 1, "truncation sends one request")
    }

    static func emptyChoicesAreRejected() async throws {
        do {
            _ = try await complete(path: "empty-single")
            expect(false, "missing choices must not become a successful empty completion")
        } catch LLMKitError.noResultReturned {
        }
    }

    static func stats() async throws -> (counts: [String: Int], bodies: [String: Any], headers: [String: Any]) {
        let (data, _) = try await URLSession.shared.data(from: server.appending(path: "stats"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (
            json["counts"] as? [String: Int] ?? [:],
            json["bodies"] as? [String: Any] ?? [:],
            json["headers"] as? [String: Any] ?? [:]
        )
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}
