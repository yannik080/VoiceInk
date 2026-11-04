import Foundation

@main
struct EnhancementOutputCheck {
    static func main() throws {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func rejected(_ output: String, _ source: String = "Bitte korrigiere den Screenshot und zeige alle Knöpfe.") -> Bool {
            AIEnhancementOutputFilter.hasIntroducedRepetition(in: output, source: source)
        }

        expect(rejected("Der Screenshot " + String(repeating: "am Ende ", count: 180)), "incident-shaped loop")
        expect(rejected(String(repeating: "Ende, ", count: 30)), "one-word loop with punctuation")
        expect(rejected(String(repeating: "Bitte passe den Screenshot an. ", count: 8)), "sentence loop")
        expect(rejected(String(repeating: "am Ende ", count: 20) + "Fertig."), "loop before response end")
        expect(!rejected("Am Ende ist alles gut. Am Ende prüfen wir das."), "normal repeated phrase")
        expect(!rejected("Ende, Ende, Ende, Ende, Ende."), "short dictated repetition")
        let dictated = String(repeating: "Bitte wiederhole diesen Satz. ", count: 20)
        expect(!rejected(dictated, dictated), "intentional dictated repetition")
        expect(!rejected(dictated.uppercased(), dictated), "capitalization preserves dictated repetition")
        expect(!rejected(dictated.replacingOccurrences(of: ".", with: "!"), dictated), "punctuation preserves dictated repetition")
        expect(!rejected("你好，世界。"), "short non-Latin output")
        expect(!rejected(""), "empty output remains the caller's responsibility")
        expect(AIEnhancementOutputFilter.filter("<think>internal</think> Hallo.") == "Hallo.", "existing reasoning filter")

        // Private history stays outside Git. Replay the saved input/output when provided locally.
        if let path = ProcessInfo.processInfo.environment["VOICEINK_INCIDENT_JSON"] {
            let rows = try JSONDecoder().decode([Incident].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let incident = rows.first else { fatalError("Missing incident") }
            expect(rejected(incident.ZENHANCEDTEXT, incident.ZTEXT), "actual incident rejected")
            expect(!rejected(incident.ZTEXT, incident.ZTEXT), "actual complete transcript preserved")
            print("Actual incident replayed: \(incident.ZTEXT.count) source characters preserved")
        }
        if let path = ProcessInfo.processInfo.environment["VOICEINK_HISTORY_JSON"] {
            let rows = try JSONDecoder().decode([Incident].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let rejectedIDs = rows.filter { rejected($0.ZENHANCEDTEXT, $0.ZTEXT) }.compactMap(\.Z_PK)
            print("History sample: \(rows.count) outputs; rejected IDs: \(rejectedIDs)")
        }
        guard failures == 0 else { exit(1) }
        print("All enhancement output checks passed")
    }

    struct Incident: Decodable {
        let Z_PK: Int?
        let ZTEXT: String
        let ZENHANCEDTEXT: String
    }
}
