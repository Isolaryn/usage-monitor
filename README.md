# Usage Monitor

Compact native macOS 13+ menu bar monitor for Codex and Claude subscription usage. SwiftUI, no dependencies, no Dock icon.

Each provider has two small rows: **5 hours** and **Weekly**, showing **percentage used** and time until reset. The menu bar uses a terminal icon for Codex and an asterisk for Claude, with single-line 13-point percentages, 5-hour then weekly, an 8-point gap between values and a 16-point gap between providers. Labels remain in the popover and hover description; the bar fits its content. The 5-hour row and menu bar value are hidden when the provider does not report that window. Missing weekly data shows a dash, never zero usage. The popover is 310 points wide, with text headers and no large icons or cards. Appearance follows macOS.

## Build and run with Nix

The flake targets **Apple Silicon (`aarch64-darwin`) on macOS 14+**, matching Nixpkgs’ Swift runtime deployment target. Swift, SwiftPM, the macOS SDK and signing tools come from the locked Nixpkgs input; a host Xcode installation is not used by the Nix build.

Run directly from GitHub:

```sh
nix run github:Isolaryn/usage-monitor
```

Or build from a checkout:

```sh
nix build
nix run
```

The bundle is at `result/Applications/Usage Monitor.app`. `nix run` opens it with macOS Launch Services. CLI arguments are forwarded to the executable:

```sh
nix run . -- --self-test
nix run . -- --diagnose
nix flake check
```

Flake outputs:

- `packages.aarch64-darwin.default` and `.usage-monitor`
- `apps.aarch64-darwin.default` and `.usage-monitor`
- `checks.aarch64-darwin.build` (build includes the offline self-tests)
- `devShells.aarch64-darwin.default` (`nix develop`)
- `overlays.default` (adds `pkgs.usage-monitor`)

Only the Swift package, sources and shared bundle metadata enter the derivation source. Local builds, result links and account credentials are excluded. The build performs no live provider calls. Keep `flake.lock` under version control. When adding source files, stage them in Git so Nix can see them.

### Consume from nix-darwin

Add this repository as a flake input:

```nix
inputs.usage-monitor.url = "github:Isolaryn/usage-monitor";
```

Include `usage-monitor` in your flake's `outputs` arguments, then add a module inside `darwinSystem.modules`:

```nix
({ pkgs, ... }: {
  environment.systemPackages = [
    usage-monitor.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
})
```

This exposes `usage-monitor` and the application bundle through nix-darwin's applications integration. Alternatively, consume `usage-monitor.overlays.default` and install `pkgs.usage-monitor`. The overlay uses the consumer's Nixpkgs, while the package output uses this flake's lock. No system configuration is modified by building this project.

For development:

```sh
nix develop
swift build -c release --disable-sandbox
```

The Nix package is ad-hoc signed for local use, not notarized for distribution. Nix updates change its store path and may require macOS to grant Keychain access again or re-enable launch at login. For persistent installation, add the package to your nix-darwin configuration.

### Build with the host Apple toolchain

The existing standalone build is also available:

```sh
./scripts/build.sh
open 'build/Usage Monitor.app'
```

Both build paths share `Resources/Info.plist`.

## Claude: local token, no status-line plugin

The monitor reads the existing Claude subscription token from `CLAUDE_CODE_OAUTH_TOKEN`, the configured Claude credential file, or the named `Claude Code-credentials` macOS Keychain item. It sends that token only to Anthropic's HTTPS OAuth usage endpoint. Requests use an ephemeral session, do not follow redirects, and do not persist tokens, usage responses, cookies, or account identities. Only polling deadlines, failure counts, and controlled error messages are saved locally. It does not rotate or overwrite Claude's credentials.

The Keychain is queried for the specific Claude item, never enumerated. Background checks cannot prompt. If macOS requires authorization, use **Allow Claude Keychain access…** or the refresh button. macOS can request access again after Claude rotates credentials or this locally signed application is rebuilt.

This account-level fetch runs independently of Claude Code sessions. No prompt or running terminal is required, and no status-line modification is required. It reads the allowance reported for the token's account, including shared app/Code usage where Anthropic pools it; it does not provide a per-app breakdown or separately billed API/SDK spending. CLI status is used for supplementary installation/sign-in/plan detection; app installations are also detected, but a desktop-only account without a readable supported token cannot be queried automatically.

The OAuth usage endpoint is used by other monitors but is not a stable public API contract. Expired tokens, missing permissions, rate limits, and unavailable responses are reported distinctly. Sign in again with Claude Code when needed. A local login does not guarantee permission to read usage.

## Codex

Finds the CLI in PATH, native user, Nix and Homebrew locations, including `/etc/profiles/per-user/<user>/bin`. Calls `account/read` and `account/rateLimits/read` via local `codex app-server` stdio. No agent turn is started.

Window identity comes from `windowDurationMins`, not primary/secondary position. A primary window can be weekly. The main `codex` bucket is kept separate from other models' quotas. If the main bucket only returns weekly usage, the 5-hour row and menu bar value are hidden; the app never substitutes another model's 5-hour allowance. API-only accounts may not expose subscription quotas.

## Refresh and missing data

Checks each provider at most once every **15 minutes**, plus up to one minute of jitter. Opening the popover only displays data. The **Refresh** button fetches immediately without waiting for the automatic interval (at most once per minute). Rate-limit cooldowns still apply, and the button explains which providers are waiting. CLI diagnostics use the automatic schedule. All requests share a persistent gate, including across processes. A local timer updates the display once per minute without making a request unless a provider is due.

For HTTP 429, retries back off to **30 minutes → 60 minutes → 2 hours**, capped at two hours for subsequent failures. A longer `Retry-After` response is always respected (both seconds and HTTP dates are supported). Missing, invalid, or zero headers never cause an immediate retry. Other failures back off from 15 minutes up to two hours. A successful response resets the backoff. Schedules survive app restarts in `~/Library/Application Support/UsageMonitor/polling.json`; a file lock prevents duplicate requests from multiple app/CLI processes.

Last successful readings are kept in memory during a failure for the same account identity, labelled with their age and a `~` prefix in the menu bar. Each provider shows its next check time. A successful response that omits the 5-hour window still hides that row. No stale usage is loaded from disk or carried over to a different account token. Reset countdowns do not invent renewed quota.

There is no published request quota established here for Claude's OAuth usage endpoint; 15 minutes is a conservative app policy, not a guaranteed safe provider limit. For comparison, [CodexBar's adaptive policy](https://github.com/steipete/CodexBar/blob/main/Sources/AdaptiveRefreshCore/AdaptiveRefreshPolicyCore.swift) uses a nominal five minutes and 15–30 minutes while idle. [Its OAuth cooldown](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageRateLimitGate.swift) also honors `Retry-After`. Anthropic documents that header for its [public API](https://platform.claude.com/docs/en/api/rate-limits), whose inference limits should not be assumed to apply to this usage endpoint.

## Previous status-line integration

The former connection button is removed. `--capture-claude` remains as a compatibility mode so existing configurations do not break. It is no longer read by the monitor. If you previously connected it, restore just the `statusLine` entry in `~/.claude/settings.json` (or `CLAUDE_CONFIG_DIR/settings.json`) from `~/Library/Application Support/UsageMonitor/previous-statusline.json`, or remove it if no original existed. Avoid overwriting newer settings with a full backup. This update does not silently alter your Claude settings.

## Validation

```sh
.build/release/UsageMonitor --self-test
.build/release/UsageMonitor --diagnose
```

Tests exercise JSON wire shapes: both providers, weekly-only primary windows, ISO/numeric resets, missing/null/malformed data, unsupported durations, over-limit clamping, credential parsing with synthetic data, and shell quoting. Diagnostics print only installation/sign-in status, usage percentages, and errors, never tokens or account identities. `--diagnose --allow-keychain` allows a native authorization prompt when needed.

## References

- [Codex app-server](https://developers.openai.com/codex/app-server)
- [CodexBar's Claude integration documentation](https://github.com/steipete/CodexBar/blob/main/docs/claude.md) — local OAuth usage source and credential format.
- [Anthropic Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api) — separate organization API billing, not implemented here.
