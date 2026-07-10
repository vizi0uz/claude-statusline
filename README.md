# claude-statusline

A portable, cross-platform status line renderer for Claude Code that displays model, effort level, context window usage, account info, and 5-hour rate limit status.

## Features

- **Rich status display:** Shows model name, effort level (color-coded), context window % (6-stage color gradient), account plan, email, hostname, LAN IP, and public IP
- **Rate limit bar:** 40-character rate limit visualization with countdown to reset
- **Cache-efficiency indicator:** Compact bar showing price-weighted cache savings pooled over the last 5 turns, appended after the Session bar — dips into yellow/red when the cached prompt prefix churns instead of being read cheaply
- **Privacy-aware:** Email, LAN IP, and public IP are only shown when explicitly enabled via environment flag
- **Portable:** Works on Windows (PowerShell 6+) and Linux/macOS (bash with jq/curl)
- **Cross-session caching:** Caches account info per session to reduce API calls; public IP is refreshed on a configurable interval instead of being fetched once and cached forever
- **VPN/multi-NIC safe LAN IP:** Detected via a routing-table lookup (which local address would the OS use to reach the internet), not by enumerating all local addresses — stays correct even with VPNs, Docker bridges, or multiple NICs
- **Auto-cleanup:** Prunes cache files older than 1 day

## Example Output

```
claude-opus [high]  ctx:42%  Free  user@example.com  myhost / 192.168.1.42 (203.0.113.7)
Session ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░ 40% used · resets in 2h 10m  ·  cache ▓▓▓▓▓▓▓▓▓░ 85%  ·  $1.21
```

With identity flag off:
```
claude-opus [high]  ctx:42%  myhost
Session ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░ 40% used · resets in 2h 10m  ·  cache ▓▓▓▓▓▓▓▓▓░ 85%  ·  $1.21
```

The hostname segment degrades gracefully: `myhost / LAN_IP (WAN_IP)` when both are known, `myhost / LAN_IP` or `myhost (WAN_IP)` if only one resolved, or plain `myhost` if neither did (e.g. identity flag off).

## Installation

### Windows (PowerShell 6+)
```powershell
.\install.ps1
```

This will:
1. Copy `statusline-command.ps1` to `~/.claude/`
2. Patch `~/.claude/settings.json` with the correct paths
3. Back up your prior settings to `settings.json.pre-statusline`

To enable identity info on this machine:
```powershell
[System.Environment]::SetEnvironmentVariable('CLAUDE_STATUSLINE_SHOW_IDENTITY', '1', 'User')
# Restart Claude Code for the change to take effect
```

Or via command line:
```cmd
setx CLAUDE_STATUSLINE_SHOW_IDENTITY 1
```

### Linux / macOS (bash)
```bash
./install.sh
```

This will:
1. Copy `statusline-command.sh` to `~/.claude/` and make it executable
2. Patch `~/.claude/settings.json` with the correct paths
3. Back up your prior settings to `settings.json.pre-statusline`

To enable identity info on this machine:
```bash
export CLAUDE_STATUSLINE_SHOW_IDENTITY=1
# Or add to ~/.bashrc or ~/.zshrc for persistence:
echo 'export CLAUDE_STATUSLINE_SHOW_IDENTITY=1' >> ~/.bashrc
```

## Privacy: The Identity Flag

By default, email, LAN IP, and public IP are **not** displayed. This is useful on shared or remote machines.

To show account email, LAN IP, and public IP (on trusted machines only):
```bash
# Windows
setx CLAUDE_STATUSLINE_SHOW_IDENTITY 1

# Linux/macOS
export CLAUDE_STATUSLINE_SHOW_IDENTITY=1
```

When the flag is off:
- Account email, LAN IP, and public IP are **not** fetched
- No network calls to `api.ipify.org` or `claude auth status`, and no local routing-table lookup
- Only model, effort, context%, and hostname are shown

When the flag is on:
- Hostname is always shown (never gated)
- LAN IP is recomputed on every render (it's a local routing-table lookup, not a network call, so there's no cost to keeping it live)
- Account plan/email and public IP are fetched and cached per session, each re-checked periodically once its own refresh interval elapses (see below) — this is what lets the display catch up if you switch accounts or your public IP changes mid-session, instead of showing whatever was true the first time this session rendered
- If a refresh fails (e.g. a DNS hiccup for the public IP, or `claude auth status` failing/timing out), the last known-good value stays on screen instead of going blank, and it's retried after the interval — not stuck until the cache expires a day later. The one exception: if `claude auth status` succeeds and reports you're logged out, plan/email are cleared immediately rather than kept stale.

## Configuring refresh intervals

Public IP and account plan/email are cached independently, each with its own refresh interval, since re-checking them costs differently (an HTTP round-trip to `api.ipify.org` vs. spawning `claude auth status`). LAN IP is not affected by either setting since it's always computed live.

Precedence for both: environment variable → JSON config file → default (60 seconds each).

```bash
# Environment variables (any positive integer, in seconds)
export CLAUDE_STATUSLINE_IP_REFRESH_SECONDS=30
export CLAUDE_STATUSLINE_ACCOUNT_REFRESH_SECONDS=30
```

Or via a config file at `~/.claude/statusline-config.json` (read on both platforms):
```json
{
  "ipRefreshSeconds": 30,
  "accountRefreshSeconds": 30
}
```

An invalid or missing value falls back to the 60-second default for that setting.

Note on resumed sessions: `claude --resume <id>` reuses the original session's cache, keyed by `session_id`. If you log into a different account and then resume a session that predates the switch, the display will pick up the new account within one `accountRefreshSeconds` window rather than showing the pre-switch account for the rest of the session.

## Dependencies

### Windows
- PowerShell 6+ (pwsh)

### Linux / macOS
- bash
- jq (JSON query tool)
- curl (HTTP client)
- For LAN IP detection: `ip` (iproute2, most Linux distros) or `route`+`ifconfig` (macOS/BSD) or `hostname -I` as fallbacks, in that order. If none are available, the LAN IP segment is simply omitted.

## Color Codes

### Effort Levels
- `low` → Blue
- `medium` → Green
- `high` → Yellow
- `xhigh` → Red
- `max` → Magenta

### Context Window % (6-stage gradient)
- 0–30%: Green (optimal)
- 30–50%: Teal (healthy)
- 50–60%: Yellow (watch)
- 60–75%: Orange (handoff zone)
- 75–83%: Red (danger)
- 83%+: Dark red (critical/lossy)

### Rate Limit Bar
- <70%: Green
- 70–90%: Yellow
- 90%+: Red

### Cache Efficiency

Shows a price-weighted cache-savings ratio pooled over the last 5 API calls in the session:
`savings = ((1 - 0.10) × cache_read - (1.25 - 1) × cache_write) / (fresh + cache_write + cache_read)`.
It's a cost-efficiency gauge, not a context-fullness one — a well-cached session reads high/green
even with heavy output; it dips when the cached prompt prefix gets invalidated and re-written
(churn) instead of being read cheaply.

- Green (≥70%): strong cache reuse, near steady state
- Yellow (0–70%): caching helps, but reuse is mediocre or recent churn is dragging the pool
- Red (<0%, `⚠`): net loss over the window — real churn

Requires `rate_limits` to be present (Claude.ai Pro/Max subscribers, after the first API
response), since it's appended after the Session bar on the same line. Shows `cache ······ warming up`
when the rolling window is still empty (mainly right after `/compact`).

## Verification

To test the status line manually:

```bash
# Windows
$json = @{
    model = @{ display_name = "claude-opus" }
    effort = @{ level = "high" }
    context_window = @{
        used_percentage = 42
        current_usage = @{
            input_tokens = 500
            cache_creation_input_tokens = 2000
            cache_read_input_tokens = 50000
            output_tokens = 1200
        }
    }
    cost = @{ total_cost_usd = 1.21 }
    session_id = "test"
    rate_limits = @{
        five_hour = @{
            used_percentage = 40
            resets_at = [DateTimeOffset]::UtcNow.AddSeconds(7800).ToUnixTimeSeconds()
        }
    }
} | ConvertTo-Json -Depth 5

$json | pwsh -NoProfile -File statusline-command.ps1
```

```bash
# Linux/macOS
json='{"model":{"display_name":"claude-opus"},"effort":{"level":"high"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":500,"cache_creation_input_tokens":2000,"cache_read_input_tokens":50000,"output_tokens":1200}},"cost":{"total_cost_usd":1.21},"session_id":"test","rate_limits":{"five_hour":{"used_percentage":40,"resets_at":'$(($(date +%s) + 7800))'}}}' 

echo "$json" | bash statusline-command.sh
```

## License

MIT
