import SwiftUI
import AppKit
import ServiceManagement

@MainActor final class Monitor: ObservableObject {
    @Published var providers = [ProviderSnapshot(name: "Codex"), ProviderSnapshot(name: "Claude")]
    @Published var refreshing = false
    @Published var message: String?
    private var timer: Timer?
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }
    func refresh(allowKeychainPrompt: Bool = false) {
        guard !refreshing else { return }; refreshing = true
        Task {
            async let codex = Task.detached(priority: .utility) { readCodex() }.value
            async let claude = Task.detached(priority: .utility) { await readClaude(allowKeychainPrompt: allowKeychainPrompt) }.value
            providers = await [codex, claude]; refreshing = false
        }
    }
    var menuDescription: String {
        providers.map { provider in
            let values = displayedPeriods(provider).map { period in
                "\(period.rawValue): \(menuValue(provider, period: period)) used"
            }.joined(separator: ", ")
            return "\(provider.name), \(values)"
        }.joined(separator: "; ")
    }
    func menuValue(_ provider: ProviderSnapshot, period: UsagePeriod) -> String {
        guard let observed = provider.observed, Date().timeIntervalSince(observed) < 300,
              let window = provider.windows.first(where: { $0.period == period }) else { return "—" }
        return "\(window.usedPercent)%"
    }
    var menuImage: NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let values = providers.map { provider in
            displayedPeriods(provider).map { NSAttributedString(string: menuValue(provider, period: $0), attributes: attrs) }
        }
        let iconWidth: CGFloat = 14
        let iconGap: CGFloat = 6
        let windowGap: CGFloat = 8
        let providerGap: CGFloat = 16
        let widths = values.map { group in
            iconWidth + iconGap + group.reduce(CGFloat(0)) { $0 + ceil($1.size().width) }
                + CGFloat(max(0, group.count - 1)) * windowGap
        }
        let size = NSSize(width: widths.reduce(0, +) + providerGap, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            var groupX: CGFloat = 0
            for index in 0..<2 {
                let symbol = NSImage(systemSymbolName: index == 0 ? "terminal" : "asterisk", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
                symbol?.draw(in: NSRect(x: groupX, y: 4, width: iconWidth, height: 14))
                var textX = groupX + iconWidth + iconGap
                for value in values[index] {
                    value.draw(at: NSPoint(x: textX, y: (size.height - value.size().height) / 2))
                    textX += ceil(value.size().width) + windowGap
                }
                groupX += widths[index] + providerGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

}

func displayedPeriods(_ provider: ProviderSnapshot) -> [UsagePeriod] {
    UsagePeriod.allCases.filter { period in
        period != .fiveHour || provider.windows.contains { $0.period == .fiveHour }
    }
}
struct UsageRow: View {
    let period: UsagePeriod
    let window: WindowUsage?
    let tint: Color
    var resetLabel: String {
        guard let reset = window?.reset else { return window == nil ? "Not reported" : "Reset unknown" }
        let seconds = reset.timeIntervalSinceNow
        guard seconds > 0 else { return "Awaiting reset" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(period.rawValue).frame(width: 46, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.12))
                    if let window {
                        Capsule().fill(window.used >= 90 ? Color.orange : tint)
                            .frame(width: geometry.size.width * Double(window.usedPercent) / 100)
                    }
                }
            }.frame(height: 4)
            Text(window.map { "\($0.usedPercent)%" } ?? "—")
                .fontWeight(.medium).monospacedDigit().frame(width: 34, alignment: .trailing)
            Text(resetLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                .monospacedDigit().frame(width: 74, alignment: .trailing)
        }.font(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(period.rawValue): \(window.map { "\($0.usedPercent) percent used" } ?? "usage not reported"), reset \(resetLabel)")
        .help(window?.reset.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "The provider did not report this window")
    }
}
struct ProviderCard: View {
    let provider: ProviderSnapshot
    private var tint: Color { provider.name == "Codex" ? Color(red: 0.25, green: 0.42, blue: 0.86) : Color(red: 0.66, green: 0.39, blue: 0.25) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Circle().fill(provider.signedIn ? tint : Color.secondary).frame(width: 5, height: 5)
                    .accessibilityLabel(provider.signedIn ? "Signed in" : "Sign-in unverified")
                Text(provider.name).font(.system(size: 12, weight: .semibold))
                if !provider.plan.isEmpty { Text(provider.plan.capitalized).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(string: provider.name == "Codex" ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage")!)
                } label: { Image(systemName: "arrow.up.right").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open \(provider.name) usage").accessibilityLabel("Open \(provider.name) usage")
            }
            ForEach(displayedPeriods(provider), id: \.self) { period in
                UsageRow(period: period, window: provider.windows.first { $0.period == period }, tint: tint)
            }
            if provider.observed == nil || provider.windows.isEmpty {
                Text(provider.status).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
struct MonitorView: View {
    @ObservedObject var monitor: Monitor
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Used · resets in").font(.system(size: 10)).foregroundStyle(.secondary)
                Button { monitor.refresh(allowKeychainPrompt: true) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.borderless).disabled(monitor.refreshing).help("Refresh usage").accessibilityLabel("Refresh usage")
            }
            Divider()
            ProviderCard(provider: monitor.providers[0])
            Divider()
            ProviderCard(provider: monitor.providers[1])
            if monitor.providers.last?.needsKeychainAccess == true {
                Button("Allow Claude Keychain access…") { monitor.refresh(allowKeychainPrompt: true) }
                    .font(.system(size: 10)).buttonStyle(.link).disabled(monitor.refreshing)
            }
            if let message = monitor.message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Text(monitor.refreshing ? "Refreshing…" : "Auto-refresh · 1 min").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Text("Menu bar: 5-hour / weekly % used")
                    Divider()
                    Toggle("Launch at login", isOn: Binding(get: { login }, set: { enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; login = SMAppService.mainApp.status == .enabled }
                        catch { monitor.message = "Login setting failed: \(error.localizedDescription)" }
                    }))
                    Divider()
                    Button("Quit Usage Monitor") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "gearshape").font(.system(size: 11)) }.menuStyle(.borderlessButton).frame(width: 20)
            }
        }.padding(12).frame(width: 310).background(.regularMaterial)
    }
}
func runDiagnostics() {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        let codex = readCodex()
        let claude = await readClaude(allowKeychainPrompt: CommandLine.arguments.contains("--allow-keychain"))
        for provider in [codex, claude] {
            print("\(provider.name): installed=\(provider.installed), signedIn=\(provider.signedIn), status=\(provider.status)")
            for period in UsagePeriod.allCases {
                let window = provider.windows.first { $0.period == period }
                print("  \(period.rawValue): \(window.map { "\($0.usedPercent)% used" } ?? "not reported")")
            }
        }
        done.signal()
    }
    done.wait()
}
@main struct UsageMonitorApp: App {
    @StateObject private var monitor: Monitor
    init() {
        if CommandLine.arguments.contains("--capture-claude") { do { try captureClaude(); exit(0) } catch { exit(1) } }
        if CommandLine.arguments.contains("--self-test") { runTests(); exit(0) }
        if CommandLine.arguments.contains("--diagnose") { runDiagnostics(); exit(0) }
        _monitor = StateObject(wrappedValue: Monitor())
    }
    var body: some Scene {
        MenuBarExtra { MonitorView(monitor: monitor) } label: {
            Image(nsImage: monitor.menuImage)
                .help(monitor.menuDescription)
                .accessibilityLabel(monitor.menuDescription)
        }.menuBarExtraStyle(.window)
    }
}
