[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$json = [Console]::In.ReadToEnd()
$data = $json | ConvertFrom-Json

$model = $data.model.display_name
$effort = $data.effort.level
$used = $data.context_window.used_percentage

$accountPlan = $null
$accountEmail = $null
$publicIp = $null
$lanIp = $null
$sessionId = $data.session_id

# IP refresh interval (seconds): env var > ~/.claude/statusline-config.json > default
$configPath = Join-Path $HOME ".claude/statusline-config.json"

$ipRefreshSeconds = $null
if ($env:CLAUDE_STATUSLINE_IP_REFRESH_SECONDS) {
    $parsed = 0
    if ([int]::TryParse($env:CLAUDE_STATUSLINE_IP_REFRESH_SECONDS, [ref]$parsed)) {
        $ipRefreshSeconds = $parsed
    }
}
if (-not $ipRefreshSeconds -and (Test-Path $configPath)) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($cfg.ipRefreshSeconds) { $ipRefreshSeconds = [int]$cfg.ipRefreshSeconds }
    } catch {}
}
# A WAN address changes on the order of hours, and every check is an outbound
# request to a third party that reveals this machine is online. Poll rarely.
if (-not $ipRefreshSeconds) { $ipRefreshSeconds = 900 }

# Account info refresh interval (seconds): env var > ~/.claude/statusline-config.json > default.
# No network cost, but the re-check spawns `claude auth status` to observe a
# value that only changes at login/logout, so it too polls slowly.
$accountRefreshSeconds = $null
if ($env:CLAUDE_STATUSLINE_ACCOUNT_REFRESH_SECONDS) {
    $parsed = 0
    if ([int]::TryParse($env:CLAUDE_STATUSLINE_ACCOUNT_REFRESH_SECONDS, [ref]$parsed)) {
        $accountRefreshSeconds = $parsed
    }
}
if (-not $accountRefreshSeconds -and (Test-Path $configPath)) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($cfg.accountRefreshSeconds) { $accountRefreshSeconds = [int]$cfg.accountRefreshSeconds }
    } catch {}
}
if (-not $accountRefreshSeconds) { $accountRefreshSeconds = 300 }

# Best-effort LAN IP: ask the OS which local address it would route outbound
# traffic from (a UDP "connect" just resolves the route, no packets sent).
# This stays correct with multiple NICs/VPNs, unlike enumerating all local
# addresses, and it's cheap enough to compute fresh every render.
function Get-LanIp {
    try {
        $socket = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        $socket.Connect("8.8.8.8", 65530)
        $ip = $socket.LocalEndPoint.Address.ToString()
        $socket.Close()
        return $ip
    } catch {
        return $null
    }
}

# Only fetch identity-related data if the flag is explicitly enabled
if ($env:CLAUDE_STATUSLINE_SHOW_IDENTITY -eq '1') {
    $lanIp = Get-LanIp
}

if ($env:CLAUDE_STATUSLINE_SHOW_IDENTITY -eq '1' -and $sessionId) {
    $accountCacheFile = "$env:TEMP\claude-statusline-account-$sessionId.json"

    # NON-BLOCKING: read only whatever identity is already cached. The slow
    # lookups (claude auth status, public IP) must NOT run on the render path.
    # Each can take seconds, and Claude Code cancels a status line command
    # when the next update arrives -- so a slow render is killed before it can
    # print, and the line then stays blank. A detached, lock-throttled
    # background process refreshes the cache instead; the values appear on a
    # later render.
    $cache = $null
    if (Test-Path $accountCacheFile) {
        try { $cache = Get-Content $accountCacheFile -Raw | ConvertFrom-Json } catch {}
    }
    $accountPlan  = $cache.plan
    $accountEmail = $cache.email
    $publicIp     = $cache.publicIp

    # The two TTLs stay independent (see README "Configuring refresh
    # intervals"): accountRefreshSeconds paces `claude auth status`,
    # ipRefreshSeconds the public-IP fetch. Re-checking periodically rather
    # than "once ever" also matters for resumed sessions, which reuse their
    # session_id -- a permanent cache would keep showing a pre-switch account
    # forever after logging into a different one mid-session.
    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $accountAge = $nowEpoch - [int64]($cache.accountCheckedAt)
    $ipAge      = $nowEpoch - [int64]($cache.ipCheckedAt)
    $accountStale = -not ($accountPlan -and $accountEmail) -or ($accountAge -ge $accountRefreshSeconds)
    $ipStale      = -not $publicIp -or ($ipAge -ge $ipRefreshSeconds)

    # Fire-and-forget refresh; the render never waits on it. At most one
    # refresher runs at a time: skip if a lock is younger than 30s, and mark
    # the lock in the parent BEFORE spawning so two back-to-back renders
    # cannot both spawn one.
    if ($accountStale -or $ipStale) {
        $lock = "$env:TEMP\claude-statusline-refresh-$sessionId.lock"
        $lockItem = Get-Item $lock -ErrorAction SilentlyContinue
        $lockFresh = $lockItem -and (((Get-Date) - $lockItem.LastWriteTime).TotalSeconds -lt 30)
        if (-not $lockFresh) {
            Set-Content -LiteralPath $lock -Value '' -ErrorAction SilentlyContinue
            # Refresher body. Single-quoted here-string: nothing is
            # interpolated here; the __PLACEHOLDER__ tokens are substituted
            # below. It renews only the component(s) whose TTL has lapsed
            # (keeping last-known-good values on failure), writes the cache,
            # prunes day-old files, then clears the lock.
            $refreshTemplate = @'
$ErrorActionPreference = 'SilentlyContinue'
$cacheFile = '__CACHE__'
$lock = '__LOCK__'
$acctTtl = [int64]__ACCT_TTL__
$ipTtl = [int64]__IP_TTL__
try {
    $plan = $null; $email = $null; $publicIp = $null
    $acctAt = [int64]0; $ipAt = [int64]0
    if (Test-Path $cacheFile) {
        try {
            $o = Get-Content $cacheFile -Raw | ConvertFrom-Json
            $plan = $o.plan; $email = $o.email; $publicIp = $o.publicIp
            $acctAt = [int64]($o.accountCheckedAt); $ipAt = [int64]($o.ipCheckedAt)
        } catch {}
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not ($plan -and $email) -or (($now - $acctAt) -ge $acctTtl)) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            # Route through cmd.exe so CreateProcess applies PATHEXT and finds
            # the claude.cmd shim (npm/nvm installs) that a bare "claude"
            # would miss.
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/c claude auth status --json'
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            if ($p.WaitForExit(6000)) {
                $auth = $p.StandardOutput.ReadToEnd() | ConvertFrom-Json
                if ($auth.loggedIn) {
                    $ti = (Get-Culture).TextInfo
                    $plan = $ti.ToTitleCase(($auth.subscriptionType -replace '_', ' '))
                    $email = $auth.email
                } else {
                    # Genuinely logged out -- do not keep a stale identity.
                    $plan = $null; $email = $null
                }
            } else {
                # Timed out -- keep last known-good and retry next interval.
                try { $p.Kill() } catch {}
            }
        } catch {}
        $acctAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    if (-not $publicIp -or (($now - $ipAt) -ge $ipTtl)) {
        # A failed fetch keeps the last known-good IP and still bumps the
        # timestamp, so a broken DNS/network is retried after the interval.
        try { $ip = Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 6; if ($ip) { $publicIp = "$ip".Trim() } } catch {}
        $ipAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    try { @{ plan = $plan; email = $email; publicIp = $publicIp; accountCheckedAt = $acctAt; ipCheckedAt = $ipAt } | ConvertTo-Json | Set-Content -LiteralPath $cacheFile -Encoding utf8 } catch {}
    try { Get-ChildItem "$env:TEMP\claude-statusline-account-*.json", "$env:TEMP\claude-statusline-refresh-*.lock" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
} finally {
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
}
'@
            $refreshSrc = $refreshTemplate.Replace('__CACHE__', $accountCacheFile).Replace('__LOCK__', $lock).Replace('__ACCT_TTL__', "$accountRefreshSeconds").Replace('__IP_TTL__', "$ipRefreshSeconds")
            try {
                $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($refreshSrc))
                Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc | Out-Null
            } catch {}
        }
    }
}

# ESC and the bar glyphs are built from code points so the script is pure
# ASCII and parses + renders identically under Windows PowerShell 5.1 and 7,
# regardless of the file's on-disk encoding. (`e is a PS 6+ escape, and a
# non-ASCII glyph literal makes the 5.1 parser choke when the .ps1 is read
# with the system ANSI code page instead of UTF-8.)
$ESC       = [char]27
$BAR_FULL  = [string][char]0x2588   # full block   (session bar, filled)
$BAR_EMPTY = [string][char]0x2591   # light shade  (bar remainder)
$BAR_CACHE = [string][char]0x2593   # medium shade (cache bar)
$SEP       = [char]0x00B7           # middot separator
$WARN      = [char]0x26A0           # warning sign

$cyan    = "${ESC}[36m"
$gray    = "${ESC}[90m"
$blue    = "${ESC}[94m"
$green   = "${ESC}[32m"
$yellow  = "${ESC}[33m"
$red     = "${ESC}[31m"
$magenta   = "${ESC}[95m"
$boldWhite = "${ESC}[1;97m"
$reset     = "${ESC}[0m"

# ---- Cache-efficiency indicator ----
# Price-weighted cache-savings ratio, pooled over the last N turns:
#   savings = ( (1 - W_READ)*R - (W_WRITE - 1)*W ) / (F + W + R)
# Scale-invariant (absolute per-token price cancels), bounded in [-(W_WRITE-1), 1-W_READ].
# context_window.current_usage is a per-call snapshot, not cumulative, so state is persisted
# per-session in the temp dir (same pattern as the account-info cache above) and pooled here.
$cacheWRead    = 0.10   # cache-read price / base-input price
$cacheWWrite   = 1.25   # cache-write price / base-input price (5-min TTL)
$cacheN        = 5      # rolling window length, in turns
$cacheGreenAt  = 0.70   # savings >= this -> green
$cacheBarCells = 10
$cacheCeil     = 1.0 - $cacheWRead

$cost = $data.cost.total_cost_usd
$cacheCurrentUsage = $data.context_window.current_usage
# prompt_id is the current user prompt's UUID (Claude Code v2.1.196+). It's the
# turn-boundary signal that stays reliable when cost is absent/frozen. Empty on
# older Claude Code -- then detection falls back to cost alone (behavior as before).
$promptId = $data.prompt_id

$cacheSid = ($sessionId -replace '[^a-zA-Z0-9_-]', '')
if (-not $cacheSid) { $cacheSid = "default" }
$cacheStateFile = Join-Path $env:TEMP "claude-statusline-cache-$cacheSid.json"

$cacheState = $null
if (Test-Path $cacheStateFile) {
    try {
        $loaded = Get-Content $cacheStateFile -Raw | ConvertFrom-Json
        if ($loaded -and ($loaded.PSObject.Properties.Name -contains 'turns')) {
            $cacheState = $loaded
        }
    } catch {}
}
if (-not $cacheState) {
    $cacheState = [PSCustomObject]@{ last_cost = $null; last_prompt_id = $null; turns = @() }
}
# ConvertFrom-Json collapses a one-element JSON array to a single object, not an array -- force it back.
$cacheTurns = @($cacheState.turns)

# Turn-boundary detection (compound OR): a new billed API call changes total_cost_usd
# (per-call granularity), and a new user prompt changes prompt_id -- either one marks a
# fresh current_usage snapshot worth logging. The prompt_id arm keeps the indicator alive
# when cost is null/frozen; the cost arm preserves per-call resolution and works on Claude
# Code older than v2.1.196 (no prompt_id). Both last_* update in the same state write, so a
# turn where both change logs exactly once. current_usage must be present either way.
$costChanged   = ($null -ne $cost) -and ($cost -ne $cacheState.last_cost)
$promptChanged = $promptId -and ($promptId -ne $cacheState.last_prompt_id)
if ($null -ne $cacheCurrentUsage -and ($costChanged -or $promptChanged)) {
    $cacheF = $cacheCurrentUsage.input_tokens
    if ($null -eq $cacheF) { $cacheF = 0 }
    $cacheWTok = $cacheCurrentUsage.cache_creation_input_tokens
    if ($null -eq $cacheWTok) { $cacheWTok = 0 }
    $cacheRTok = $cacheCurrentUsage.cache_read_input_tokens
    if ($null -eq $cacheRTok) { $cacheRTok = 0 }

    $cacheTurns += [PSCustomObject]@{ F = $cacheF; W = $cacheWTok; R = $cacheRTok }
    if ($cacheTurns.Count -gt $cacheN) {
        $cacheTurns = $cacheTurns[($cacheTurns.Count - $cacheN)..($cacheTurns.Count - 1)]
    }

    try {
        $newCacheState = [PSCustomObject]@{ last_cost = $cost; last_prompt_id = $promptId; turns = $cacheTurns }
        $cacheTmpFile = "$cacheStateFile.tmp"
        $newCacheState | ConvertTo-Json -Depth 5 | Out-File $cacheTmpFile -Encoding utf8
        Move-Item -Force $cacheTmpFile $cacheStateFile
    } catch {}

    # Prune cache-window files older than 1 day -- gated to at most once per day via a marker
    # file. A turn boundary can hit multiple times per session, and a wildcard directory scan
    # over a busy temp dir (e.g. antivirus scanning each entry) can cost multiple seconds; a
    # per-write scan would make that tax recur on every single turn.
    try {
        $cachePruneMarker = Join-Path $env:TEMP ".claude-statusline-cache-pruned-at"
        $cachePruneDue = $true
        if (Test-Path $cachePruneMarker) {
            $cachePruneAge = (Get-Date) - (Get-Item $cachePruneMarker).LastWriteTime
            if ($cachePruneAge.TotalSeconds -lt 86400) { $cachePruneDue = $false }
        }
        if ($cachePruneDue) {
            Set-Content -Path $cachePruneMarker -Value "" -NoNewline -ErrorAction SilentlyContinue
            Get-ChildItem "$env:TEMP\claude-statusline-cache-*.json" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne "claude-statusline-cache-$cacheSid.json" -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

$cachePoolF = 0; $cachePoolW = 0; $cachePoolR = 0
foreach ($cacheTurn in $cacheTurns) {
    $cachePoolF += $cacheTurn.F
    $cachePoolW += $cacheTurn.W
    $cachePoolR += $cacheTurn.R
}
$cacheDenom = $cachePoolF + $cachePoolW + $cachePoolR

# ctx% stage framework (truecolor, thresholds from the Opus staging table)
$ctxStage1 = "${ESC}[38;2;34;197;94m"    # 0-30%   Green    #22c55e  Optimal
$ctxStage2 = "${ESC}[38;2;20;184;166m"   # 30-50%  Teal     #14b8a6  Healthy
$ctxStage3 = "${ESC}[38;2;234;179;8m"    # 50-60%  Yellow   #eab308  Watch
$ctxStage4 = "${ESC}[38;2;249;115;22m"   # 60-75%  Orange   #f97316  Handoff zone
$ctxStage5 = "${ESC}[38;2;239;68;68m"    # 75-83%  Red      #ef4444  Danger
$ctxStage6 = "${ESC}[38;2;153;27;27m"    # 83%+    Dark red #991b1b  Critical/lossy

$line = ""

if ($model) {
    $line = "${boldWhite}${model}${reset}"
}

if ($effort) {
    $effortColor = switch ($effort) {
        "low"    { $blue }
        "medium" { $green }
        "high"   { $yellow }
        "xhigh"  { $red }
        "max"    { $magenta }
        default  { $yellow }
    }
    $line = "$line ${effortColor}[${effort}]${reset}"
}

if ($null -ne $used) {
    $usedInt = [int][math]::Round($used)
    $ctxColor = if ($usedInt -ge 83) { $ctxStage6 } elseif ($usedInt -ge 75) { $ctxStage5 } elseif ($usedInt -ge 60) { $ctxStage4 } elseif ($usedInt -ge 50) { $ctxStage3 } elseif ($usedInt -ge 30) { $ctxStage2 } else { $ctxStage1 }
    $line = "$line  ${ctxColor}ctx:${usedInt}%${reset}"
}

if ($accountPlan -or $accountEmail) {
    $line = "$line  ${green}${accountPlan}${reset} ${gray}${SEP}${reset} ${cyan}${accountEmail}${reset}"
}

$hostname = $env:COMPUTERNAME
if ($hostname) {
    $line = "$line  ${cyan}${hostname}${reset}"
    if ($lanIp) {
        $line = "$line ${gray}/${reset} ${cyan}${lanIp}${reset}"
    }
    # On a host whose outbound address is already public, LAN and WAN are the
    # same string; printing it twice is noise.
    if ($publicIp -and $publicIp -ne $lanIp) {
        $line = "$line ${gray}(${reset}${cyan}${publicIp}${reset}${gray})${reset}"
    }
}

Write-Host $line

$fiveHour = $data.rate_limits.five_hour
if ($fiveHour -and $null -ne $fiveHour.used_percentage -and $null -ne $fiveHour.resets_at) {
    $pct = [int][math]::Round($fiveHour.used_percentage)

    $barWidth = 40
    $filled = [int][math]::Round(($pct / 100) * $barWidth)
    if ($filled -gt $barWidth) { $filled = $barWidth }
    if ($filled -lt 0) { $filled = 0 }
    $bar = ($BAR_FULL * $filled) + ($BAR_EMPTY * ($barWidth - $filled))

    # Same 6-stage gradient as ctx% (warmer as the session fills)
    $barColor = if ($pct -ge 83) { $ctxStage6 } elseif ($pct -ge 75) { $ctxStage5 } elseif ($pct -ge 60) { $ctxStage4 } elseif ($pct -ge 50) { $ctxStage3 } elseif ($pct -ge 30) { $ctxStage2 } else { $ctxStage1 }

    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # Use [long] (Int64): resets_at is epoch seconds, and the difference can
    # exceed Int32 range, which would throw a cast error and blank the timer.
    $remaining = [long]($fiveHour.resets_at - $nowEpoch)
    $stale = $remaining -le 0
    if ($remaining -lt 0) { $remaining = 0 }
    $hours = [int][math]::Floor($remaining / 3600)
    $minutes = [int][math]::Floor(($remaining % 3600) / 60)
    $resetStr = if ($hours -gt 0) { "${hours}h ${minutes}m" } else { "${minutes}m" }

    # resets_at has passed, but Claude Code only refreshes rate_limits on the
    # next API call, so pct above may be a stale snapshot too -- flag it rather
    # than show a countdown frozen at 0m.
    $sessionLine = if ($stale) {
        "${gray}Session ${reset}${barColor}${bar}${reset} ${pct}% used ${gray}${SEP} awaiting refresh${reset}"
    } else {
        "${gray}Session ${reset}${barColor}${bar}${reset} ${pct}% used ${gray}${SEP}${reset} resets in ${resetStr}"
    }

    # Cache-efficiency segment, appended after the Session bar on the same line.
    if ($cacheDenom -eq 0) {
        $cacheSegment = "  ${gray}${SEP}${reset}  ${gray}cache ${SEP}${SEP}${SEP}${SEP}${SEP}${SEP} warming up${reset}"
    } else {
        $cacheSavings = ((1 - $cacheWRead) * $cachePoolR - ($cacheWWrite - 1) * $cachePoolW) / $cacheDenom

        if ($cacheSavings -lt 0) { $cacheColor = $red }
        elseif ($cacheSavings -lt $cacheGreenAt) { $cacheColor = $yellow }
        else { $cacheColor = $green }

        $cacheClamped = $cacheSavings
        if ($cacheClamped -lt 0) { $cacheClamped = 0 }
        if ($cacheClamped -gt $cacheCeil) { $cacheClamped = $cacheCeil }
        $cacheFill = [int][math]::Round($cacheClamped / $cacheCeil * $cacheBarCells)
        $cacheBar = ($BAR_CACHE * $cacheFill) + ($BAR_EMPTY * ($cacheBarCells - $cacheFill))

        $cacheWarn = ""
        if ($cacheSavings -lt 0) { $cacheWarn = " ${red}${WARN}${reset}" }

        $cachePct = [int][math]::Round($cacheSavings * 100)

        $cacheCostStr = ""
        if ($null -ne $cost) {
            $cacheCostFmt = $cost.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
            $cacheCostStr = "  ${gray}${SEP}${reset}  " + '$' + $cacheCostFmt
        }

        $cacheSegment = "  ${gray}${SEP}${reset}  ${gray}cache${reset} ${cacheColor}${cacheBar} ${cachePct}%${reset}${cacheWarn}${cacheCostStr}"
    }
    $sessionLine = "$sessionLine$cacheSegment"

    Write-Host -NoNewline $sessionLine
}
