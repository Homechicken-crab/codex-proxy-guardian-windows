[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallDirectory = '',
    [switch]$StartNow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $InstallDirectory = Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'
}
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
$sourceDirectory = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$taskName = 'CodexProxyGuardian'
$guardianPath = Join-Path $InstallDirectory 'Guardian.ps1'
$configPath = Join-Path $InstallDirectory 'config.json'
$markerPath = Join-Path $InstallDirectory '.install.json'
$existingManagedInstall = $false
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    try {
        $existingMarker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existingManagedInstall = $existingMarker.product -eq 'CodexProxyGuardian' -and
            [string]::Equals([string]$existingMarker.installDirectory, $InstallDirectory, [StringComparison]::OrdinalIgnoreCase)
    }
    catch { }
}

if ($InstallDirectory -eq [IO.Path]::GetPathRoot($InstallDirectory)) {
    throw 'Refusing to install into a drive root.'
}

if (-not $PSCmdlet.ShouldProcess($InstallDirectory, 'Install Codex Proxy Guardian and register its current-user logon task')) {
    return
}

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallDirectory 'logs') -Force | Out-Null

$managedFiles = @('Guardian.ps1', 'TaskRunner.ps1', 'Status.ps1', 'Diagnose.ps1', 'Uninstall.ps1', 'README.md', 'CHANGELOG.md', 'VALIDATION.md')
foreach ($name in $managedFiles) {
    $source = Join-Path $sourceDirectory $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required file is missing: $source" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDirectory $name) -Force
}
if ($existingManagedInstall) {
    Remove-Item -LiteralPath (Join-Path $InstallDirectory 'RunHidden.vbs') -Force -ErrorAction SilentlyContinue
}

$sourceConfig = Join-Path $sourceDirectory 'config.json'
Copy-Item -LiteralPath $sourceConfig -Destination (Join-Path $InstallDirectory 'config.default.json') -Force
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Copy-Item -LiteralPath $sourceConfig -Destination $configPath
}

$marker = [pscustomobject][ordered]@{
    product = 'CodexProxyGuardian'
    schemaVersion = 1
    installedAt = [DateTimeOffset]::Now.ToString('o')
    installedBySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    installDirectory = $InstallDirectory
    taskName = $taskName
    networkSettingsModified = $false
    environmentSettingsModified = $false
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Depth 4), $utf8)

$powerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$taskRunnerPath = Join-Path $InstallDirectory 'TaskRunner.ps1'
$arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$taskRunnerPath`""
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$userName = $identity.Name

$action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userName
try { $trigger.Delay = 'PT20S' } catch { }
$principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$definition = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Validates the current proxy and restarts only OpenAI Codex when a stable proxy endpoint changes.'
try { $definition.Settings.Hidden = $true } catch { }

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    # Ask the old instance to leave its loop first. This prevents an orphaned
    # child process during upgrades and releases the named mutex cleanly.
    $stopRequest = Join-Path $InstallDirectory 'stop.request'
    [IO.File]::WriteAllText($stopRequest, [DateTimeOffset]::Now.ToString('o'), $utf8)
    $runnerPattern = [Regex]::Escape([IO.Path]::GetFullPath($taskRunnerPath))
    $deadline = [DateTimeOffset]::Now.AddSeconds(12)
    do {
        $oldRunners = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @('powershell.exe', 'pwsh.exe') -and [string]$_.CommandLine -match $runnerPattern
        })
        if ($oldRunners.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::Now -lt $deadline)
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    foreach ($oldRunner in $oldRunners) {
        Stop-Process -Id $oldRunner.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
Register-ScheduledTask -TaskName $taskName -InputObject $definition -Force | Out-Null

if ($StartNow) {
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 2
}

$task = Get-ScheduledTask -TaskName $taskName
[pscustomobject][ordered]@{
    installed = $true
    installDirectory = $InstallDirectory
    taskName = $taskName
    taskState = [string]$task.State
    startNow = [bool]$StartNow
    systemProxyChanged = $false
    winHttpChanged = $false
    environmentChanged = $false
} | ConvertTo-Json -Depth 4
