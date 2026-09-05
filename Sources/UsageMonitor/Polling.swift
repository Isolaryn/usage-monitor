import Foundation
import Darwin

struct PollSchedule: Codable {
    static let interval: TimeInterval = 15 * 60
    var nextAttempt = Date.distantPast
    var failures = 0
    var lastError: String?
    var lastAttempt: Date?
    var inFlightUntil: Date?
    var rateLimitUntil: Date?

    mutating func reserve(now: Date, manual: Bool, repair: Bool = false) -> Bool {
        guard (inFlightUntil ?? .distantPast) <= now else { return false }
        // Older schedule files encode a rate-limit cooldown in lastError/nextAttempt.
        let legacyLimit = lastError == ClaudeUsageError.rateLimited.errorDescription ? nextAttempt : nil
        guard (rateLimitUntil ?? legacyLimit ?? .distantPast) <= now else { return false }
        let manualDue = manual && now.timeIntervalSince(lastAttempt ?? .distantPast) >= 60
        guard isDue(at: now) || manualDue || repair else { return false }
        lastAttempt = now
        inFlightUntil = now.addingTimeInterval(60)
        nextAttempt = now.addingTimeInterval(Self.interval)
        lastError = nil
        return true
    }

    func isDue(at now: Date) -> Bool { now >= nextAttempt }
    mutating func record(_ result: ProviderSnapshot, now: Date, jitter: TimeInterval = 0) {
        inFlightUntil = nil
        rateLimitUntil = nil
        if result.observed != nil {
            failures = 0
            lastError = nil
            nextAttempt = now.addingTimeInterval(Self.interval + max(0, jitter))
        } else {
            failures = min(failures + 1, 8)
            let base: TimeInterval = result.rateLimited ? 30 * 60 : Self.interval
            let delay = min(2 * 60 * 60, base * pow(2, Double(failures - 1)))
            nextAttempt = max(now.addingTimeInterval(delay + max(0, jitter)), result.retryAfter ?? now)
            lastError = result.status
            if result.rateLimited { rateLimitUntil = nextAttempt }
        }
    }
}
func retryAfterDate(_ header: String?, now: Date = Date()) -> Date? {
    guard let header else { return nil }
    let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
        return now.addingTimeInterval(seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
}

// Share the request gate across app restarts, multiple copies and CLI diagnostics.
// The file contains only scheduling metadata and controlled error messages.
func updateSchedules<T>(directory: URL = support, _ action: (inout [String: PollSchedule]) throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let descriptor = open(directory.appendingPathComponent("polling.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
    defer { flock(descriptor, LOCK_UN) }
    let url = directory.appendingPathComponent("polling.json")
    var schedules: [String: PollSchedule] = [:]
    if FileManager.default.fileExists(atPath: url.path) {
        schedules = try JSONDecoder().decode([String: PollSchedule].self, from: Data(contentsOf: url))
    }
    let result = try action(&schedules)
    try JSONEncoder().encode(schedules).write(to: url, options: .atomic)
    return result
}
func readProvider(_ name: String, allowKeychainPrompt: Bool = false, manual: Bool = false) async -> ProviderSnapshot {
    do {
        let reservation = try updateSchedules { schedules -> (Bool, PollSchedule) in
            var schedule = schedules[name] ?? PollSchedule()
            // Keychain repair is local, but can only bypass the gate for that error.
            let repair = allowKeychainPrompt && schedule.lastError == ClaudeUsageError.keychainLocked.errorDescription
            guard schedule.reserve(now: Date(), manual: manual, repair: repair) else { return (false, schedule) }
            schedules[name] = schedule
            return (true, schedule)
        }
        guard reservation.0 else {
            var result = ProviderSnapshot(name: name)
            result.skipped = true
            result.nextAttempt = reservation.1.nextAttempt
            result.status = reservation.1.lastError == ClaudeUsageError.rateLimited.errorDescription
                ? "Waiting to retry after earlier rate limit"
                : reservation.1.lastError ?? "Waiting for scheduled check"
            result.needsKeychainAccess = reservation.1.lastError == ClaudeUsageError.keychainLocked.errorDescription
            return result
        }
        var result: ProviderSnapshot
        if name == "Claude" { result = await fetchClaude(allowKeychainPrompt: allowKeychainPrompt) }
        else { result = fetchCodex() }
        result.nextAttempt = try updateSchedules { schedules in
            var schedule = schedules[name] ?? PollSchedule()
            schedule.record(result, now: Date(), jitter: Double.random(in: 0...60))
            schedules[name] = schedule
            return schedule.nextAttempt
        }
        return result
    } catch {
        var result = ProviderSnapshot(name: name)
        result.status = "Cannot read polling schedule · checks paused"
        result.skipped = true
        return result
    }
}
func keepingLastReading(_ result: ProviderSnapshot, previous: ProviderSnapshot) -> ProviderSnapshot {
    if result.skipped, previous.observed != nil || previous.nextAttempt != nil {
        var retained = previous
        retained.nextAttempt = result.nextAttempt
        if result.status == "Waiting to retry after earlier rate limit" {
            retained.status = result.status
            retained.isStale = retained.observed != nil
        }
        return retained
    }
    var result = result
    if result.observed == nil, result.identity != nil, result.identity == previous.identity,
       previous.observed != nil {
        result.windows = previous.windows
        result.observed = previous.observed
        result.isStale = true
    }
    return result
}
