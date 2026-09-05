import Foundation
import Darwin
import Security
import LocalAuthentication
import CryptoKit

typealias JSON = [String: Any]
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/UsageMonitor")
func decode(_ data: Data) -> JSON { (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:] }
func encode(_ value: JSON) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func executable(_ name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":") + ["\(home)/.local/bin", "\(home)/.nix-profile/bin", "/etc/profiles/per-user/\(NSUserName())/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    return paths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
}
enum UsagePeriod: String, CaseIterable {
    case fiveHour = "5 hours"
    case weekly = "Weekly"
}
struct WindowUsage {
    let period: UsagePeriod
    let used: Double
    let reset: Date?
    var label: String { period.rawValue }
    var remaining: Int { Int(max(0, min(100, 100 - used)).rounded()) }
    var usedPercent: Int { Int(min(100, max(0, used)).rounded()) }
}
func usageDate(_ value: Any?) -> Date? {
    if let epoch = value as? Double, epoch.isFinite { return Date(timeIntervalSince1970: epoch) }
    guard let string = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}
func windows(_ value: JSON, claude: Bool) -> [WindowUsage] {
    let keys = claude ? ["five_hour", "seven_day"] : ["primary", "secondary"]
    return keys.compactMap { key in
        guard let window = value[key] as? JSON,
              let used = (claude ? (window["utilization"] ?? window["used_percentage"]) : window["usedPercent"]) as? Double,
              used.isFinite, used >= 0 else { return nil }
        let period: UsagePeriod
        if claude { period = key == "five_hour" ? .fiveHour : .weekly }
        else {
            // A primary window may be weekly. Never infer its duration from its position.
            switch window["windowDurationMins"] as? Int {
            case 300: period = .fiveHour
            case 10080: period = .weekly
            default: return nil
            }
        }
        return WindowUsage(period: period, used: used, reset: usageDate(window[claude ? "resets_at" : "resetsAt"]))
    }
}
struct ProviderSnapshot {
    var name: String
    var installed = false
    var signedIn = false
    var status = "Checking installation…"
    var plan = ""
    var windows: [WindowUsage] = []
    var observed: Date?
    var needsKeychainAccess = false
    var rateLimited = false
    var retryAfter: Date?
    var nextAttempt: Date?
    var skipped = false
    var isStale = false
    var identity: String?
}
final class Command {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private var timer: DispatchSourceTimer?
    init(_ path: String, _ args: [String], timeout: Double = 20) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [URL(fileURLWithPath: path).deletingLastPathComponent().path, env["PATH"] ?? "", "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = env
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [process] in if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume(); self.timer = timer
    }
    func stop() { timer?.cancel(); if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close() }
    deinit { stop() }
    func send(_ json: JSON) throws { try input.fileHandleForWriting.write(contentsOf: encode(json) + Data([10])) }
    func response(_ id: Int) throws -> JSON {
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 {
                let obj = decode(line); line.removeAll(keepingCapacity: true)
                if obj["id"] as? Int == id {
                    guard obj["error"] == nil else { throw NSError(domain: "Provider rejected request", code: 1) }
                    return obj["result"] as? JSON ?? [:]
                }
            } else { line.append(byte) }
            if line.count > 2_000_000 { throw NSError(domain: "Response too large", code: 2) }
        }
        throw NSError(domain: "Provider unavailable or timed out", code: 3)
    }
}
func fetchCodex() -> ProviderSnapshot {
    var state = ProviderSnapshot(name: "Codex")
    guard let path = executable("codex") else { state.status = "Install Codex CLI to connect"; return state }
    state.installed = true
    do {
        let rpc = try Command(path, ["app-server"]); defer { rpc.stop() }
        try rpc.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "usage_monitor", "version": "0.1.0"]]])
        _ = try rpc.response(1)
        try rpc.send(["method": "initialized"])
        try rpc.send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
        let account = try rpc.response(2)["account"] as? JSON
        guard let account else { state.status = "Sign in with codex login"; return state }
        state.identity = (try? encode(account)).map { SHA256.hash(data: $0).description }
        state.signedIn = true; state.plan = account["planType"] as? String ?? account["type"] as? String ?? ""
        try rpc.send(["id": 3, "method": "account/rateLimits/read"])
        let limits = try rpc.response(3)
        let buckets = limits["rateLimitsByLimitId"] as? JSON
        let quota = buckets?["codex"] as? JSON ?? limits["rateLimits"] as? JSON ?? [:]
        state.windows = windows(quota, claude: false)
        state.observed = Date()
        state.status = state.windows.isEmpty ? "No subscription limits available for this account" : "Live account usage"
    } catch { state.status = state.signedIn ? "Usage unavailable · retry refresh" : "Could not verify sign-in · retry refresh" }
    return state
}
enum ClaudeUsageError: LocalizedError {
    case missingToken, keychainLocked, expired, forbidden, rateLimited, http(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .missingToken: return "No Claude subscription token found · sign in with Claude Code"
        case .keychainLocked: return "Allow Keychain access to read Claude usage"
        case .expired: return "Claude login expired · sign in again with Claude Code"
        case .forbidden: return "Claude token cannot read usage · sign in again with Claude Code"
        case .rateLimited: return "Claude rate-limited usage checks · retry later"
        case .http(let code): return "Claude usage unavailable (HTTP \(code))"
        case .invalidResponse: return "Claude returned an unrecognized usage response"
        }
    }
}
func tokenFromCredentials(_ data: Data) -> String? {
    let oauth = decode(data)["claudeAiOauth"] as? JSON
    guard let token = oauth?["accessToken"] as? String, !token.isEmpty else { return nil }
    return token
}
func claudeToken(allowKeychainPrompt: Bool) throws -> String {
    if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty { return token }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
    if let data = try? Data(contentsOf: directory.appendingPathComponent(".credentials.json")), let token = tokenFromCredentials(data) { return token }
    // Query only Claude's named credential item. Never enumerate the user's Keychain.
    let context = LAContext()
    context.interactionNotAllowed = !allowKeychainPrompt
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled { throw ClaudeUsageError.keychainLocked }
    guard status == errSecSuccess, let data = result as? Data, let token = tokenFromCredentials(data) else { throw ClaudeUsageError.missingToken }
    return token
}
// Credentials must never follow an HTTP redirect, even to another Anthropic endpoint.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
func fetchClaude(allowKeychainPrompt: Bool = false) async -> ProviderSnapshot {
    var state = ProviderSnapshot(name: "Claude")
    state.installed = executable("claude") != nil || FileManager.default.fileExists(atPath: "/Applications/Claude.app") || FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app").path)
    // CLI status distinguishes a login problem from a usage-fetch problem.
    if let path = executable("claude"), let command = try? Command(path, ["auth", "status", "--json"]) {
        try? command.input.fileHandleForWriting.close()
        let auth = decode(command.output.fileHandleForReading.readDataToEndOfFile()); command.stop()
        state.signedIn = auth["loggedIn"] as? Bool ?? false
        state.plan = auth["subscriptionType"] as? String ?? auth["authMethod"] as? String ?? ""
    }
    do {
        let token = try claudeToken(allowKeychainPrompt: allowKeychainPrompt)
        state.identity = SHA256.hash(data: Data(token.utf8)).description
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("UsageMonitor/0.2", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClaudeUsageError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401: throw ClaudeUsageError.expired
        case 403: throw ClaudeUsageError.forbidden
        case 429:
            state.rateLimited = true
            state.retryAfter = retryAfterDate(response.value(forHTTPHeaderField: "Retry-After"))
            throw ClaudeUsageError.rateLimited
        default: throw ClaudeUsageError.http(response.statusCode)
        }
        let payload = decode(data)
        guard payload.keys.contains("five_hour") || payload.keys.contains("seven_day") else { throw ClaudeUsageError.invalidResponse }
        state.signedIn = true
        state.windows = windows(payload, claude: true)
        state.observed = Date()
        state.status = state.windows.isEmpty ? "Claude did not report quota windows" : "Live account usage"
    } catch {
        state.status = (error as? ClaudeUsageError)?.errorDescription ?? "Claude usage request failed · check your connection"
        if case ClaudeUsageError.keychainLocked = error { state.needsKeychainAccess = true }
    }
    return state
}
func captureClaude() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let payload = decode(data)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Store quota fields only; never persist prompts, paths, credentials or session identifiers.
    let saved: JSON = ["observed": Date().timeIntervalSince1970, "rate_limits": payload["rate_limits"] as? JSON ?? [:]]
    try encode(saved).write(to: support.appendingPathComponent("claude-usage.json"), options: .atomic)
    let original = (try? Data(contentsOf: support.appendingPathComponent("previous-statusline.json"))).map(decode)
    if let cmd = original?["command"] as? String, !cmd.isEmpty {
        let child = Process(); let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh"); child.arguments = ["-c", cmd]; child.standardInput = pipe
        try child.run(); try pipe.fileHandleForWriting.write(contentsOf: data); try pipe.fileHandleForWriting.close(); child.waitUntilExit()
    } else { print("Claude · Usage Monitor connected") }
}
