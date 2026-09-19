[CmdletBinding()]
param([switch]$Live)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$errors = @()
$files = @('Guardian.ps1', 'TaskRunner.ps1', 'LaunchCodex.ps1', 'Install.ps1', 'Status.ps1', 'Diagnose.ps1', 'Uninstall.ps1', 'SelfTest.ps1', 'Build-Release.ps1')
foreach ($name in $files) {
    $path = Join-Path $PSScriptRoot $name
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    foreach ($item in @($parseErrors)) { $errors += "${name}: $($item.Message)" }
}

$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$requiredFiles = @('README.md', 'CHANGELOG.md', 'VALIDATION.md', 'config.json', 'TaskRunner.vbs', 'LaunchCodex.ps1')
foreach ($name in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
        $errors += "Required release file is missing: $name"
    }
}
if ($config.sourceMode -ne 'SystemProxy') { $errors += 'Default sourceMode is not SystemProxy.' }
if (-not [bool]$config.injectProcessProxy) { $errors += 'Process-scoped proxy injection must be enabled for Codex WebSocket traffic.' }
if (-not [bool]$config.webSocketProbeEnabled) { $errors += 'WebSocket route probing must be enabled.' }
if ($config.webSocketProbeHost -ne 'chatgpt.com') { $errors += 'WebSocket probe host must match the Codex ChatGPT endpoint.' }
if ([bool]$config.allowRemoteProxy) { $errors += 'Remote proxy endpoints must be disabled by default.' }
if ([int]$config.debounceSeconds -lt 10) { $errors += 'Debounce window is too short.' }
if ([int]$config.maxRestartsInWindow -gt 3) { $errors += 'Restart rate limit is too permissive.' }
if ([int]$config.codexLaunchGraceSeconds -lt 10) { $errors += 'Codex launch verification window is too short.' }

$liveResult = $null
if ($Live) {
    $guardian = Join-Path $PSScriptRoot 'Guardian.ps1'
    $liveText = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $guardian -Command Once 2>&1 | Out-String
    try { $liveResult = $liveText | ConvertFrom-Json } catch { $errors += "Live check did not return JSON: $liveText" }
    if ($liveResult -and -not $liveResult.probe.ok) {
        $errors += "Live proxy probe failed: $($liveResult.probe.detail)"
    }
    elseif ($liveResult) {
        $wsOk = $liveResult.probe.PSObject.Properties['webSocketOk']
        $wsDetail = $liveResult.probe.PSObject.Properties['webSocketDetail']
        if ($null -eq $wsOk -or -not [bool]$wsOk.Value) {
            $detail = if ($null -ne $wsDetail) { [string]$wsDetail.Value } else { 'WebSocket result was missing.' }
            $errors += "Live WebSocket route probe failed: $detail"
        }
    }
}

[pscustomobject][ordered]@{
    passed = ($errors.Count -eq 0)
    errors = $errors
    live = $liveResult
} | ConvertTo-Json -Depth 10

if ($errors.Count -gt 0) { exit 1 }
