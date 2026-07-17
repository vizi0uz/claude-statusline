# claude-statusline

[![npm installer · cc-statusline](https://img.shields.io/badge/npm%20installer-cc--statusline-blue)](https://www.npmjs.com/package/@viziouz/cc-statusline)

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

### Quick install (npx) — recommended

The scripts in this repo are also published as a zero-clone installer, [`@viziouz/cc-statusline`](https://github.com/vizi0uz/cc-statusline) on npm:

```bash
npx @viziouz/cc-statusline@latest
```

This copies a self-contained Node launcher plus the platform scripts into `~/.claude/cc-statusline/` and merges a `statusLine` block into `~/.claude/settings.json`, backing up your prior settings to `settings.json.bak` first. Works on Windows, macOS, and Linux with one command; requires Node.js ≥14.14.

On a real terminal it asks whether to show identity info (Plan/Email/LAN/WAN IP — off by default); skip the prompt with an explicit flag:
```bash
npx @viziouz/cc-statusline@latest setup --show-identity     # turn identity fields on
npx @viziouz/cc-statusline@latest setup --no-show-identity  # keep them off
```

To uninstall:
```bash
npx @viziouz/cc-statusline@latest uninstall
# non-interactive / scripted:
npx @viziouz/cc-statusline@latest uninstall --yes
```
This removes the `statusLine` block it added (only if it still points at its own launcher) and deletes `~/.claude/cc-statusline`.

### Manual install (from this repo)

Prefer this if you're developing or auditing this repo directly, or don't want to use npm.

#### Windows (PowerShell 6+)
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

#### Linux / macOS (bash)
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
- The slow lookups (`claude auth status` and the public-IP fetch) never run on the render path: a detached background process refreshes the per-session cache and the render only reads it. Claude Code cancels an in-flight status line command when the next update arrives, so a render that waited on those calls could be killed before printing — leaving the line blank. The trade-off: a fresh session's first render shows the line without plan/email/public IP, and they appear on a later render a few seconds after launch. Tip: setting `statusLine.refreshInterval` in `settings.json` makes Claude Code re-run the script every N seconds, so the freshly cached identity shows up promptly even while you're idle.

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
- PowerShell — either Windows PowerShell 5.1 (preinstalled) or PowerShell 6+ (pwsh). The script source is pure ASCII and parses and renders identically under both.

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

## Understanding the Cache-Efficiency Indicator

### What it measures

The indicator answers one specific question: *how efficiently is Claude Code reusing cached
context over the last few turns, in dollar terms.* It is **not** a context-window-fullness
indicator — that's what the separate `ctx NN%` segment is for. This one exists to catch the
case where you're quietly burning money because the cache keeps getting invalidated and
rewritten instead of being read back cheaply.

### Where the numbers come from

Every request spends tokens of four kinds:

- **input** (fresh, uncached) — baseline price, 1×
- **output** — the most expensive tokens, but deliberately excluded from this indicator (it's
  the actual product of the turn, not a loss)
- **cache write** — writing into the cache, priced above baseline (~1.25×) — a premium paid so
  it can be read cheaply later
- **cache read** — reading from the cache, nearly free (~0.1×) — the entire point of caching

The formula, in plain terms: *how much you saved by reading from cache, minus how much you
overpaid to write to it, divided by total input volume* — pooled over a rolling window of the
last 5 turns rather than the whole session, so it stays responsive to what's happening right now.

### Reading the zones

| Zone | Meaning | What's happening | What to do |
| --- | --- | --- | --- |
| 🟢 Green, ≥70% | Normal, expected | Cache is being reused heavily; reads are cheap. A settled session typically sits around 80–90% | Nothing — this is healthy |
| 🟡 Yellow, 0–70% | Transitional | Either a large new file/context was just loaded (cache hasn't warmed up yet) or one recent turn went badly | Watch a couple of turns — if it recovers to green on its own, it was just onboarding new context |
| 🔴 Red, <0% + `⚠` | Real problem | Over the last ~5 turns you're net *losing* money on caching — paying more for writes than you're saving on reads. This is churn (the cache keeps getting invalidated) | Worth investigating — see below |

One important nuance: a single expensive cache write (e.g. you just fed the model a large file)
is normal and expected to dip the indicator into yellow for a turn or two — that's not a
problem. Only worry if it stays **red for several turns in a row** — that's the actual signal
that the cache isn't sticking.

### What causes sustained churn

Typical causes of persistent churn:

- Jumping between unrelated tasks/files every turn, never letting context settle
- Something at the start of the prompt changes on every turn (a timestamp, a random ID),
  breaking the cached prefix
- Running `/compact` too often — each one resets the cache and forces a re-warm

### Limitations

- **Doesn't track output tokens** — a session with huge model responses will still read green,
  even if output dominates the bill. That's deliberate (this indicator is about caching, not
  total spend), but it's easy to mistake green for "everything is cheap."
- **The 5-turn window is an arbitrary tradeoff** — shorter and it jitters on every small turn;
  longer and it stops reacting to a current problem. 5 is a reasonable default, not a tuned
  constant.
- **Doesn't explain *why* churn happened** — red means "bad," not which file or request
  pattern broke the cache. Diagnosis is on you.
- **Depends on hardcoded price multipliers (0.1× / 1.25×).** The formula itself is
  price-independent (that's a feature), but if Anthropic changes the *structure* of cache
  discounts (not just the price), those constants need a manual update — they won't pick it up
  automatically.
- **State is persisted to disk** (`~/.claude/cc-cache-window-*.json`) — deleting that file
  mid-session resets the window for a few turns, and the indicator will briefly show "warming up"
  until it accumulates new data.
- **An onboarding dip into yellow/red is easy to mistake for a real problem** if you don't know
  about it in advance (see the zones table above) — which is why `⚠` exists as a distinct strong
  signal marker rather than just relying on the color transition.

### Note on Plan (Pro/Max) limits

Anthropic's own docs describe Claude Code plan limits (Pro/Max/Team) as compute-based rather
than message-count-based, and state that prompt caching bills turns after the first at a much
cheaper cache-read rate. In principle that means efficient cache reuse (this indicator staying
green) should make the same amount of real work consume *less* of your 5-hour/weekly limit than
if the cache kept churning (red). The exact token-to-percent-of-limit conversion isn't published,
though, so treat this indicator as a proxy signal for wasteful spend, not a precise plan-limit
calculator. **Unverified:** some non-official, third-party reports mention a caching-related bug
around March 2026 that caused plan limits to burn down far faster than normal for affected users;
take that specific claim with appropriate skepticism, since it isn't sourced from official
Anthropic documentation.

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
