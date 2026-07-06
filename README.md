<img width="1024" height="138" alt="image" src="https://github.com/user-attachments/assets/53fe7a54-de9b-43de-aee9-27c8304abbf5" />

# claude-statusline

A portable, cross-platform status line renderer for Claude Code that displays model, effort level, context window usage, account info, and 5-hour rate limit status.

## Features

- **Rich status display:** Shows model name, effort level (color-coded), context window % (6-stage color gradient), account plan, email, and hostname
- **Rate limit bar:** 40-character rate limit visualization with countdown to reset
- **Privacy-aware:** Email and public IP are only shown when explicitly enabled via environment flag
- **Portable:** Works on Windows (PowerShell 6+) and Linux/macOS (bash with jq/curl)
- **Cross-session caching:** Caches account info per session to reduce API calls
- **Auto-cleanup:** Prunes cache files older than 1 day

## Example Output

```
claude-opus [high]  ctx:42%  Free  user@example.com  myhost
Session ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░ 40% used · resets in 2h 10m
```

With identity flag off:
```
claude-opus [high]  ctx:42%  myhost
Session ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░ 40% used · resets in 2h 10m
```

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

By default, email and public IP are **not** displayed. This is useful on shared or remote machines.

To show account email and public IP (on trusted machines only):
```bash
# Windows
setx CLAUDE_STATUSLINE_SHOW_IDENTITY 1

# Linux/macOS
export CLAUDE_STATUSLINE_SHOW_IDENTITY=1
```

When the flag is off:
- Account email and public IP are **not** fetched
- No network calls to `api.ipify.org` or `claude auth status`
- Only model, effort, context%, and hostname are shown

When the flag is on:
- Hostname is always shown (never gated)
- Email and public IP are fetched and cached per session
- If the network is unavailable, cached values are used (or omitted if no cache exists)

## Dependencies

### Windows
- PowerShell 6+ (pwsh)

### Linux / macOS
- bash
- jq (JSON query tool)
- curl (HTTP client)

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

## Verification

To test the status line manually:

```bash
# Windows
$json = @{
    model = @{ display_name = "claude-opus" }
    effort = @{ level = "high" }
    context_window = @{ used_percentage = 42 }
    session_id = "test"
    rate_limits = @{
        five_hour = @{
            used_percentage = 40
            resets_at = (Get-Date).AddSeconds(7800).ToUnixTimeSeconds()
        }
    }
} | ConvertTo-Json

$json | pwsh -NoProfile -File statusline-command.ps1
```

```bash
# Linux/macOS
json='{"model":{"display_name":"claude-opus"},"effort":{"level":"high"},"context_window":{"used_percentage":42},"session_id":"test","rate_limits":{"five_hour":{"used_percentage":40,"resets_at":'$(($(date +%s) + 7800))'}}}' 

echo "$json" | bash statusline-command.sh
```

## License

MIT
