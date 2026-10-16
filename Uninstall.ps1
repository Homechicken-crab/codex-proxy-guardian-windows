[CmdletBinding(SupportsShouldProcess)]
param([string]$CodexHome='')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxyConfig.ps1')
$homePath = Get-CodexHomePath $CodexHome
$envPath = Join-Path $homePath '.env'
$statePath = Join-Path $homePath 'proxy-setup-state.json'
$state = Read-ProxyState $statePath
if (-not $state) { Write-Output '{"removed":false,"reason":"No v2 setup state found; no files changed."}'; return }
Assert-PlainFilePath $envPath
if (-not $PSCmdlet.ShouldProcess('Codex local proxy configuration', 'Restore only unchanged proxy assignments owned by this setup')) { return }
$conflicts = @()
if ([IO.File]::Exists($envPath)) {
    $text = [IO.File]::ReadAllText($envPath)
    $restored = Restore-ProxyEnvText -Text $text -State $state
    $conflicts = @($restored.Conflicts)
    if (-not $state.originalEnvExisted -and -not $restored.Text) { [IO.File]::Delete($envPath) }
    else { Write-AtomicText $envPath $restored.Text }
}
[IO.File]::Delete($statePath)
[pscustomobject]@{ removed=$true; preservedUserModifiedKeys=$conflicts; codexRestarted=$false; systemNetworkSettingsChanged=$false } | ConvertTo-Json -Depth 3
