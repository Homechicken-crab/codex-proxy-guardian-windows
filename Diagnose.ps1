[CmdletBinding()]
param([string]$CodexHome='', [switch]$Live, [switch]$Doctor, [string]$CodexExecutable='')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxyConfig.ps1')
$homePath = Get-CodexHomePath $CodexHome
$envPath = Join-Path $homePath '.env'
$values = @{}
if ([IO.File]::Exists($envPath)) {
    foreach ($line in [IO.File]::ReadAllLines($envPath)) {
        $assignment = Get-ProxyAssignment $line
        if ($assignment) { $values[$assignment.Key] = $assignment.Value }
    }
}
$report = [ordered]@{
    version='2.0.0'; envFilePresent=([IO.File]::Exists($envPath))
    managedStatePresent=([IO.File]::Exists((Join-Path $homePath 'proxy-setup-state.json')))
    proxyKeysPresent=@($script:ProxyKeys | Where-Object { $values.ContainsKey($_) })
    endpoint='[redacted]'; backgroundMonitorRequired=$false
}
if ($Live) {
    if ($values.ContainsKey('HTTPS_PROXY')) { $report.unauthenticatedRoute = Test-HttpProxyRoute ($values['HTTPS_PROXY'].Trim().Trim('"').Trim("'")) }
    else { $report.unauthenticatedRoute = [pscustomobject]@{ Reachable=$false; Note='No HTTPS_PROXY assignment was found.' } }
}
if ($Doctor) {
    if (-not $CodexExecutable) {
        $command = Get-Command codex.exe -ErrorAction SilentlyContinue
        if ($command) { $CodexExecutable = $command.Source }
        else {
            $bin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
            if (Test-Path -LiteralPath $bin) {
                $candidate = Get-ChildItem -LiteralPath $bin -Filter codex.exe -File -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($candidate) { $CodexExecutable = $candidate.FullName }
            }
        }
    }
    if (-not $CodexExecutable -or -not (Test-Path -LiteralPath $CodexExecutable -PathType Leaf)) { throw 'Cannot locate Codex. Pass -CodexExecutable with its executable path.' }
    $savedHome = [Environment]::GetEnvironmentVariable('CODEX_HOME','Process')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_HOME',$homePath,'Process')
        $raw = @(& $CodexExecutable doctor --json 2>$null) -join [Environment]::NewLine
        $doctorReport = $raw | ConvertFrom-Json
        $checks = @()
        foreach ($name in @('network.env','network.provider_reachability','network.websocket_reachability')) {
            $property = $doctorReport.checks.PSObject.Properties[$name]
            if ($property) {
                $check = $property.Value
                $checks += [pscustomobject]@{ id=$name; status=$check.status; durationMs=$check.durationMs }
            }
        }
        $report.nativeCodexChecks = $checks
        $report.note = 'Only a successful authenticated native WebSocket check validates the signed-in route. Paths, identities, endpoints, tokens and raw doctor details are omitted.'
    }
    catch { throw 'Native doctor was unavailable or returned an unsupported report. Run codex doctor --help locally; do not publish raw logs.' }
    finally { [Environment]::SetEnvironmentVariable('CODEX_HOME',$savedHome,'Process') }
}
$report | ConvertTo-Json -Depth 5
