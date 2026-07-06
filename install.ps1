#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install claude-statusline on Windows (PowerShell 6+)
.DESCRIPTION
    Copies statusline-command.ps1 to ~/.claude, patches settings.json with absolute paths.
    Backs up prior settings.json to settings.json.pre-statusline.
#>

# Resolve home directory
$homeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$claudeDir = Join-Path $homeDir ".claude"

# Check PowerShell version
$psVersion = $PSVersionTable.PSVersion.Major
if ($psVersion -lt 6) {
    Write-Error "PowerShell 6+ required. Found: $psVersion"
    exit 1
}

# Create .claude directory if missing
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    Write-Host "Created $claudeDir"
}

# Copy statusline-command.ps1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceScript = Join-Path $scriptDir "statusline-command.ps1"
$destScript = Join-Path $claudeDir "statusline-command.ps1"

if (-not (Test-Path $sourceScript)) {
    Write-Error "statusline-command.ps1 not found in $scriptDir"
    exit 1
}

Copy-Item -Path $sourceScript -Destination $destScript -Force
Write-Host "Copied statusline-command.ps1 to $destScript"

# Resolve settings.json
$settingsJson = Join-Path $claudeDir "settings.json"
$backupJson = Join-Path $claudeDir "settings.json.pre-statusline"

# Read existing settings or create empty structure
$settings = @{}
if (Test-Path $settingsJson) {
    # Back up existing if this is the first install
    if (-not (Test-Path $backupJson)) {
        Copy-Item -Path $settingsJson -Destination $backupJson
        Write-Host "Backed up prior settings.json to settings.json.pre-statusline"
    }
    try {
        $settings = Get-Content $settingsJson -Raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "Could not parse existing settings.json, starting fresh"
        $settings = @{}
    }
}

# Update statusLine block with absolute path
$settings.statusLine = @{
    type          = "command"
    command       = "pwsh -NoProfile -File $destScript"
    refreshInterval = 30
}

# Write updated settings.json with utf8 encoding
$json = $settings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($settingsJson, $json, [System.Text.Encoding]::UTF8)
Write-Host "Patched settings.json with statusLine command at $destScript"

Write-Host ""
Write-Host "Installation complete!"
Write-Host ""
Write-Host "To show email + public IP on trusted machines, set:"
Write-Host "  [System.Environment]::SetEnvironmentVariable('CLAUDE_STATUSLINE_SHOW_IDENTITY', '1', 'User')"
Write-Host "Or via setx (command line):"
Write-Host "  setx CLAUDE_STATUSLINE_SHOW_IDENTITY 1"
Write-Host ""
Write-Host "Otherwise, only model, effort, context%, and hostname are shown."
