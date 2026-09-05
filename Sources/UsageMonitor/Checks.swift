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
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var throttled = ProviderSnapshot(name: "Claude")
    throttled.rateLimited = true
    throttled.status = "Rate limited"
    var schedule = PollSchedule()
    precondition(schedule.isDue(at: now))
    for delay in [1800.0, 3600, 7200, 7200] {
        schedule.record(throttled, now: now)
        precondition(schedule.nextAttempt == now.addingTimeInterval(delay))
        precondition(!schedule.isDue(at: now.addingTimeInterval(delay - 1)))
        precondition(schedule.isDue(at: now.addingTimeInterval(delay)))
    }
    precondition(retryAfterDate("120", now: now) == now.addingTimeInterval(120))
    precondition(retryAfterDate("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == Date(timeIntervalSince1970: 1445412480))
    precondition(retryAfterDate("invalid", now: now) == nil)
    precondition(retryAfterDate("-1", now: now) == nil)
    precondition(retryAfterDate("inf", now: now) == nil)
    throttled.retryAfter = now.addingTimeInterval(10_000)
    schedule.record(throttled, now: now)
    precondition(schedule.nextAttempt == throttled.retryAfter)
    throttled.retryAfter = retryAfterDate("0", now: now)
    schedule.record(throttled, now: now)
    precondition(schedule.nextAttempt == now.addingTimeInterval(7200))
    var good = ProviderSnapshot(name: "Claude")
    good.observed = now
    good.identity = "fixture-account"
    good.windows = claude
    schedule.record(good, now: now, jitter: 60)
    precondition(schedule.failures == 0 && schedule.lastError == nil)
    precondition(schedule.nextAttempt == now.addingTimeInterval(960))
    throttled.identity = good.identity
    let retained = keepingLastReading(throttled, previous: good)
    precondition(retained.isStale && retained.windows.count == 2 && retained.observed == now)
    throttled.identity = "different-account"
    precondition(keepingLastReading(throttled, previous: good).windows.isEmpty)
    var emptySuccess = good
    emptySuccess.windows = []
    precondition(keepingLastReading(emptySuccess, previous: good).windows.isEmpty)
    var unavailable = ProviderSnapshot(name: "Codex")
    unavailable.status = "Unavailable"
    schedule = PollSchedule()
    schedule.record(unavailable, now: now)
    precondition(schedule.nextAttempt == now.addingTimeInterval(900))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try! updateSchedules(directory: directory) { $0["Claude"] = schedule }
    let restored = try! updateSchedules(directory: directory) { $0["Claude"]! }
    precondition(restored.nextAttempt == schedule.nextAttempt && !restored.isDue(at: now))
    print("Passed: polling cadence, exponential backoff, Retry-After, cooldown persistence and stale account isolation")
    print("Passed: window identity, both providers, ISO dates, missing/malformed windows, clamping, credential shape and quoting")
}
