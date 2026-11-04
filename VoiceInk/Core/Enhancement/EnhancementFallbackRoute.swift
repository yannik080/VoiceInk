import Foundation

/// Which provider and model take over a dictation enhancement when the configured provider refuses it.
enum EnhancementFallbackRoute {
    /// Groq models that Cerebras serves as well, so the fallback keeps the same model and accuracy.
    /// Groq's free tier refused requests on 3 Oct 2026 although no quota had been used that day.
    static let cerebrasModelForGroqModel: [String: String] = [
        "qwen/qwen3.8-27b": "qwen-3.8-27b",
        "openai/gpt-oss-120b": "gpt-oss-120b",
    ]

    /// - Parameter provider: `AIProvider.rawValue` of the configured provider.
    /// - Returns: `AIProvider.rawValue` and model name of the fallback, or `nil` when there is none.
    static func fallback(forProvider provider: String, model: String) -> (provider: String, model: String)? {
        guard provider == "Groq", let cerebrasModel = cerebrasModelForGroqModel[model] else { return nil }
        return ("Cerebras", cerebrasModel)
    }
}
