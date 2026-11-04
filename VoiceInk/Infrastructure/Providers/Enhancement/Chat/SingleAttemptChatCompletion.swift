import Foundation
import LLMkit

/// Sends one OpenAI-compatible chat completion request, without LLMkit's built-in retries.
///
/// `OpenAILLMClient.chatCompletion` repeats HTTP 429 and 5xx responses after 1 s and 2 s. Dictation
/// enhancement already retries in `AIEnhancementService` (see `EnhancementRetryPolicy`), and the two
/// loops together turned one Groq rate-limit rejection into nine requests and about 13 s on "Enhancing".
/// The request matches `OpenAILLMClient.chatCompletion`. HTTP and transport failures use
/// `LLMKitError`; truncated completions use `ResponseError` so the transcript can be preserved.
enum SingleAttemptChatCompletion {
    enum ResponseError: Error {
        case outputTruncated
    }

    static func openAICompatible(
        baseURL: URL,
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        temperature: Double = 0.3,
        reasoningEffort: String? = nil,
        extraBody: [String: Any]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMKitError.missingAPIKey
        }

        var allMessages = messages
        if let systemPrompt, !systemPrompt.isEmpty {
            allMessages.insert(.system(systemPrompt), at: 0)
        }

        var body: [String: Any] = [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "stream": false
        ]
        if let reasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }
        for (key, value) in extraBody ?? [:] {
            body[key] = value
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMKitError.encodingError
        }
        request.httpBody = httpBody

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMKitError.timeout
        } catch {
            try Task.checkCancellation()
            throw LLMKitError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.networkError("No HTTP response received.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMKitError.httpError(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? "No error details"
            )
        }

        let completion: Response
        do {
            completion = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LLMKitError.decodingError(error.localizedDescription)
        }
        guard let choice = completion.choices.first else { throw LLMKitError.noResultReturned }
        if let reason = choice.finish_reason?.lowercased(),
            ["length", "max_tokens", "max_output_tokens"].contains(reason)
        {
            throw ResponseError.outputTruncated
        }
        guard !choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMKitError.noResultReturned
        }
        return choice.message.content
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }

            let message: Message
            let finish_reason: String?
        }

        let choices: [Choice]
    }
}
