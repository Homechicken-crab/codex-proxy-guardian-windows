[CmdletBinding(SupportsShouldProcess)]
param([string]$ProxyUrl='', [string]$CodexHome='', [switch]$SkipProbe, [string]$LegacyInstallDirectory='', [switch]$SkipLegacyCleanup)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxyConfig.ps1')
. (Join-Path $PSScriptRoot 'LegacyMigration.ps1')
$homePath = Get-CodexHomePath $CodexHome
if ($homePath.TrimEnd('\') -eq [IO.Path]::GetPathRoot($homePath).TrimEnd('\')) { throw 'CODEX_HOME must not be a drive root.' }
$envPath = Join-Path $homePath '.env'
$statePath = Join-Path $homePath 'proxy-setup-state.json'
Assert-PlainFilePath $envPath
Assert-PlainFilePath $statePath
if (-not $ProxyUrl) { $ProxyUrl = Get-WindowsHttpProxy }
$proxy = ConvertTo-LocalHttpProxy $ProxyUrl
if (-not $PSCmdlet.ShouldProcess('Codex local proxy configuration', 'Set proxy variables in CODEX_HOME/.env and retire verified v1 startup entries')) { return }
if (-not $SkipProbe) {
    $probe = Test-HttpProxyRoute $proxy
    if (-not $probe.Reachable) { throw ('Proxy route check failed at ' + $probe.Stage + '. No .env changes were made. For intentional offline setup, verify the port and use -SkipProbe.') }
}
$oldEnvExists = [IO.File]::Exists($envPath)
$oldText = if ($oldEnvExists) { [IO.File]::ReadAllText($envPath) } else { '' }
$oldStateExists = [IO.File]::Exists($statePath)
$oldStateText = if ($oldStateExists) { [IO.File]::ReadAllText($statePath) } else { '' }
$state = Read-ProxyState $statePath
$values = [ordered]@{ HTTP_PROXY=$proxy; HTTPS_PROXY=$proxy; ALL_PROXY=$proxy; NO_PROXY=(Get-NoProxyValue $oldText) }
if (-not $state) {
    $state = [pscustomobject]@{ product='CodexProxyGuardian'; schemaVersion=2; originalEnvExisted=$oldEnvExists; originalLines=(Get-OriginalProxyLines $oldText); values=$values }
}
else { $state.values = $values }
$newText = Set-ProxyEnvText -Text $oldText -Values $values
$migration = [pscustomobject]@{ Migrated=$false; RemovedEntries=0 }
if (-not $SkipLegacyCleanup) { $migration = Disable-LegacyGuardian -AdditionalDirectory $LegacyInstallDirectory }
New-Item -ItemType Directory -Path $homePath -Force | Out-Null
try {
    Write-AtomicText $statePath ($state | ConvertTo-Json -Depth 5)
    Write-AtomicText $envPath $newText
}
catch {
    if ($oldStateExists) { Write-AtomicText $statePath $oldStateText }
    elseif ([IO.File]::Exists($statePath)) { [IO.File]::Delete($statePath) }
    if ($oldEnvExists) { Write-AtomicText $envPath $oldText }
    elseif ([IO.File]::Exists($envPath)) { [IO.File]::Delete($envPath) }
    throw 'Could not save proxy configuration; restoration was attempted.'
}
[pscustomobject]@{
    configured=$true; version='2.0.0'; proxy='[local HTTP proxy]'; variables=$script:ProxyKeys
    legacyEntriesRetired=$migration.RemovedEntries; backgroundTaskCreated=$false
    codexRestarted=$false; systemNetworkSettingsChanged=$false
    nextStep='If Codex is already open, fully quit and reopen it once. Future normal launches read .env automatically. Keep the VPN HTTP/mixed port stable.'
} | ConvertTo-Json -Depth 3
