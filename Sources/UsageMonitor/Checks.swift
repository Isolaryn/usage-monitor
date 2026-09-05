import Foundation

func runTests() {
    func parse(_ value: JSON, claude: Bool) -> [WindowUsage] {
        windows(decode(try! encode(value)), claude: claude)
    }
    let codex = parse([
        "primary": ["usedPercent": 67.0, "windowDurationMins": 10080],
        "secondary": NSNull()
    ], claude: false)
    precondition(codex.count == 1 && codex[0].period == .weekly && codex[0].usedPercent == 67)
    precondition(!codex.contains { $0.period == .fiveHour }, "Weekly-only responses must not become 5-hour data")
    let both = parse([
        "primary": ["usedPercent": 25.0, "windowDurationMins": 300],
        "secondary": ["usedPercent": 50.0, "windowDurationMins": 10080]
    ], claude: false)
    precondition(both.map(\.period) == [.fiveHour, .weekly])
    precondition(both.map(\.remaining) == [75, 50])
    let claude = parse([
        "five_hour": ["utilization": 12.5, "resets_at": "2026-09-05T15:30:00.123Z"],
        "seven_day": ["utilization": 48.0, "resets_at": "2026-09-10T15:30:00Z"]
    ], claude: true)
    precondition(claude.count == 2 && claude.allSatisfy { $0.reset != nil })
    precondition(claude.map(\.usedPercent) == [13, 48])
    precondition(parse(["five_hour": NSNull(), "seven_day": ["utilization": 0.0]], claude: true).map(\.period) == [.weekly])
    precondition(parse(["five_hour": ["utilization": 110.0]], claude: true).first?.remaining == 0)
    precondition(parse(["five_hour": ["utilization": "invalid"]], claude: true).isEmpty)
    precondition(parse(["primary": ["usedPercent": 10.0, "windowDurationMins": 60]], claude: false).isEmpty)
    precondition(parse([:], claude: false).isEmpty)
    precondition(usageDate("invalid") == nil)
    precondition(usageDate(100.0)?.timeIntervalSince1970 == 100)
    precondition(tokenFromCredentials(Data(#"{"claudeAiOauth":{"accessToken":"fixture-only"}}"#.utf8)) == "fixture-only")
    precondition(tokenFromCredentials(Data(#"{"mcpOAuth":{}}"#.utf8)) == nil)
    precondition(shellQuote("a'b") == "'a'\\''b'")
    print("Passed: window identity, both providers, ISO dates, missing/malformed windows, clamping, credential shape and quoting")
}
