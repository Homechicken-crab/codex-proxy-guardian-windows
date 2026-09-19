[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$KeepLogs,
    [switch]$KeepConfig,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$installDirectory = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$expectedDirectory = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian')).TrimEnd('\')
$markerPath = Join-Path $installDirectory '.install.json'
$taskName = 'CodexProxyGuardian'
$startupLinkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'CodexProxyGuardian.lnk'
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$desktopLinkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex (Proxy).lnk'

if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw 'Install marker is missing; refusing recursive removal.'
}
$marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($marker.product -ne 'CodexProxyGuardian' -or $marker.installDirectory -ne $installDirectory) {
    throw 'Install marker does not match this directory; refusing removal.'
}
if (-not $Force -and -not [string]::Equals($installDirectory, $expectedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Non-default install directory requires -Force: $installDirectory"
}

if (-not $PSCmdlet.ShouldProcess($installDirectory, 'Stop and unregister Codex Proxy Guardian, then remove its owned files')) {
    return
}

$guardian = Join-Path $installDirectory 'Guardian.ps1'
if (Test-Path -LiteralPath $guardian) {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $guardian -Command Stop | Out-Null
    Start-Sleep -Seconds 2
}

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
if (Test-Path -LiteralPath $startupLinkPath -PathType Leaf) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupLinkPath)
    $expectedRunner = [IO.Path]::GetFullPath((Join-Path $installDirectory 'TaskRunner.vbs'))
    if ([string]::Equals([IO.Path]::GetFullPath($shortcut.TargetPath), [IO.Path]::GetFullPath("$env:SystemRoot\System32\wscript.exe"), [StringComparison]::OrdinalIgnoreCase) -and
        [string]$shortcut.Arguments -like "*$expectedRunner*") {
        Remove-Item -LiteralPath $startupLinkPath -Force
    }
}
if (Test-Path -LiteralPath $runKeyPath) {
    $runValue = [string](Get-ItemPropertyValue -LiteralPath $runKeyPath -Name 'CodexProxyGuardian' -ErrorAction SilentlyContinue)
    $expectedRunner = [IO.Path]::GetFullPath((Join-Path $installDirectory 'TaskRunner.vbs'))
    if ($runValue -like "*$expectedRunner*") {
        Remove-ItemProperty -LiteralPath $runKeyPath -Name 'CodexProxyGuardian' -ErrorAction SilentlyContinue
    }
}
if (Test-Path -LiteralPath $desktopLinkPath -PathType Leaf) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($desktopLinkPath)
    $expectedLauncher = [IO.Path]::GetFullPath((Join-Path $installDirectory 'LaunchCodex.ps1'))
    if ([string]::Equals([IO.Path]::GetFullPath($shortcut.TargetPath), [IO.Path]::GetFullPath("$env:SystemRoot\System32\conhost.exe"), [StringComparison]::OrdinalIgnoreCase) -and
        [string]$shortcut.Arguments -like "*$expectedLauncher*") {
        Remove-Item -LiteralPath $desktopLinkPath -Force
    }
}

# Terminate only a lingering PowerShell whose command line contains this exact
# Guardian.ps1 or TaskRunner.ps1 path. The current task directly owns TaskRunner.
$guardianPattern = [Regex]::Escape([IO.Path]::GetFullPath($guardian))
$runnerPattern = [Regex]::Escape([IO.Path]::GetFullPath((Join-Path $installDirectory 'TaskRunner.ps1')))
$lingering = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -in @('powershell.exe', 'pwsh.exe') -and
        ([string]$_.CommandLine -match $guardianPattern -or [string]$_.CommandLine -match $runnerPattern)
})
foreach ($process in $lingering) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

$archiveDirectory = $null
if ($KeepLogs -or $KeepConfig) {
    $archiveDirectory = Join-Path $env:LOCALAPPDATA ("CodexProxyGuardian-Archive-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $archiveDirectory -Force | Out-Null
    if ($KeepLogs -and (Test-Path -LiteralPath (Join-Path $installDirectory 'logs'))) {
        Copy-Item -LiteralPath (Join-Path $installDirectory 'logs') -Destination $archiveDirectory -Recurse
    }
    if ($KeepConfig -and (Test-Path -LiteralPath (Join-Path $installDirectory 'config.json'))) {
        Copy-Item -LiteralPath (Join-Path $installDirectory 'config.json') -Destination $archiveDirectory
    }
}

# The marker validation above constrains this recursive deletion to the owned install directory.
Set-Location -LiteralPath $env:TEMP
Remove-Item -LiteralPath $installDirectory -Recurse -Force

[pscustomobject][ordered]@{
    uninstalled = $true
    taskRemoved = $true
    installDirectoryRemoved = -not (Test-Path -LiteralPath $installDirectory)
    archiveDirectory = $archiveDirectory
    systemProxyChanged = $false
    winHttpChanged = $false
    environmentChanged = $false
    codexRestarted = $false
} | ConvertTo-Json -Depth 4
