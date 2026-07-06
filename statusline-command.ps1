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
$sessionId = $data.session_id

# Only fetch identity-related data if the flag is explicitly enabled
if ($env:CLAUDE_STATUSLINE_SHOW_IDENTITY -eq '1' -and $sessionId) {
    $accountCacheFile = "$env:TEMP\claude-statusline-account-$sessionId.json"

    $cache = $null
    if (Test-Path $accountCacheFile) {
        try { $cache = Get-Content $accountCacheFile -Raw | ConvertFrom-Json } catch {}
    }

    $accountPlan = $cache.plan
    $accountEmail = $cache.email
    $publicIp = $cache.publicIp
    $cacheDirty = $false

    $accountAlreadyValid = $cache.accountChecked -or ($accountPlan -and $accountEmail)
    if (-not $accountAlreadyValid) {
        $cacheDirty = $true
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = "claude"
            $psi.Arguments = "auth status --json"
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($proc.WaitForExit(3000)) {
                $auth = $proc.StandardOutput.ReadToEnd() | ConvertFrom-Json
                if ($auth.loggedIn) {
                    $textInfo = (Get-Culture).TextInfo
                    $accountPlan = $textInfo.ToTitleCase(($auth.subscriptionType -replace '_', ' '))
                    $accountEmail = $auth.email
                }
            } else {
                $proc.Kill()
            }
        } catch {}
    }

    $ipAlreadyValid = $cache.ipChecked -or $publicIp
    if (-not $ipAlreadyValid) {
        $cacheDirty = $true
        try {
            $publicIp = Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 3
        } catch {}
    }

    if ($cacheDirty) {
        try {
            @{
                plan           = $accountPlan
                email          = $accountEmail
                publicIp       = $publicIp
                accountChecked = $true
                ipChecked      = $true
            } | ConvertTo-Json | Out-File $accountCacheFile -Encoding utf8
        } catch {}

        # Prune cache files from past sessions so %TEMP% doesn't accumulate them.
        try {
            Get-ChildItem "$env:TEMP\claude-statusline-account-*.json" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne "claude-statusline-account-$sessionId.json" -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

$cyan    = "`e[36m"
$gray    = "`e[90m"
$blue    = "`e[94m"
$green   = "`e[32m"
$yellow  = "`e[33m"
$red     = "`e[31m"
$magenta   = "`e[95m"
$boldWhite = "`e[1;97m"
$reset     = "`e[0m"

# ctx% stage framework (truecolor, thresholds from the Opus staging table)
$ctxStage1 = "`e[38;2;34;197;94m"    # 0-30%   Green    #22c55e  Optimal
$ctxStage2 = "`e[38;2;20;184;166m"   # 30-50%  Teal     #14b8a6  Healthy
$ctxStage3 = "`e[38;2;234;179;8m"    # 50-60%  Yellow   #eab308  Watch
$ctxStage4 = "`e[38;2;249;115;22m"   # 60-75%  Orange   #f97316  Handoff zone
$ctxStage5 = "`e[38;2;239;68;68m"    # 75-83%  Red      #ef4444  Danger
$ctxStage6 = "`e[38;2;153;27;27m"    # 83%+    Dark red #991b1b  Critical/lossy

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
    $line = "$line  ${green}${accountPlan}${reset} ${gray}·${reset} ${cyan}${accountEmail}${reset}"
}

$hostname = $env:COMPUTERNAME
if ($hostname) {
    if ($publicIp) {
        $line = "$line  ${cyan}${hostname}${reset} ${gray}(${reset}${cyan}${publicIp}${reset}${gray})${reset}"
    } else {
        $line = "$line  ${cyan}${hostname}${reset}"
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
    $bar = ('█' * $filled) + ('░' * ($barWidth - $filled))

    # Same 6-stage gradient as ctx% (warmer as the session fills)
    $barColor = if ($pct -ge 83) { $ctxStage6 } elseif ($pct -ge 75) { $ctxStage5 } elseif ($pct -ge 60) { $ctxStage4 } elseif ($pct -ge 50) { $ctxStage3 } elseif ($pct -ge 30) { $ctxStage2 } else { $ctxStage1 }

    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $remaining = [int]($fiveHour.resets_at - $nowEpoch)
    if ($remaining -lt 0) { $remaining = 0 }
    $hours = [int][math]::Floor($remaining / 3600)
    $minutes = [int][math]::Floor(($remaining % 3600) / 60)
    $resetStr = if ($hours -gt 0) { "${hours}h ${minutes}m" } else { "${minutes}m" }

    $sessionLine = "${gray}Session ${reset}${barColor}${bar}${reset} ${pct}% used ${gray}·${reset} resets in ${resetStr}"
    Write-Host -NoNewline $sessionLine
}
