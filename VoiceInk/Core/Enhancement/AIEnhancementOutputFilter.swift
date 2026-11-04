import Foundation

struct AIEnhancementOutputFilter {
    /// Reject only substantial repetition that the model added. Dictated repetitions remain valid.
    /// Check the whole response: a generation loop can stop before the end of the response.
    static func hasIntroducedRepetition(in output: String, source: String) -> Bool {
        let outputTokens = tokens(in: output)
        let sourceTokens = tokens(in: source)
        guard outputTokens.count >= 24 else { return false }

        for width in 1...min(12, outputTokens.count / 6) {
            var start = 0
            while start + width * 6 <= outputTokens.count {
                let phrase = Array(outputTokens[start..<(start + width)])
                let repetitions = runLength(of: phrase, in: outputTokens, startingAt: start)
                if repetitions >= 6, repetitions * width >= 24 {
                    var sourceRepetitions = 0
                    for index in sourceTokens.indices where sourceTokens[index] == phrase[0] {
                        sourceRepetitions = max(
                            sourceRepetitions,
                            runLength(of: phrase, in: sourceTokens, startingAt: index)
                        )
                        if sourceRepetitions + 3 > repetitions { break }
                    }
                    if repetitions >= sourceRepetitions + 3 { return true }
                }
                // Keep the last block so a different run starting there can still be found.
                start += max(1, (repetitions - 1) * width)
            }
        }
        return false
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func runLength(of phrase: [String], in tokens: [String], startingAt start: Int) -> Int {
        var count = 0
        var index = start
        while index + phrase.count <= tokens.count,
            tokens[index..<(index + phrase.count)].elementsEqual(phrase)
        {
            count += 1
            index += phrase.count
        }
        return count
    }

    static func filter(_ text: String) -> String {
        var processedText = text
        let patterns = [
            #"(?s)<thinking>(.*?)</thinking>"#,
            #"(?s)<think>(.*?)</think>"#,
            #"(?s)<reasoning>(.*?)</reasoning>"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(processedText.startIndex..., in: processedText)
                processedText = regex.stringByReplacingMatches(
                    in: processedText, options: [], range: range, withTemplate: "")
            }
        }

        return processedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
