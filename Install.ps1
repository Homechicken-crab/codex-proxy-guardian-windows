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

$managedFiles = @('Guardian.ps1', 'TaskRunner.ps1', 'TaskRunner.vbs', 'LaunchCodex.ps1', 'Status.ps1', 'Diagnose.ps1', 'Uninstall.ps1', 'README.md', 'CHANGELOG.md', 'VALIDATION.md')
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

$wscriptExe = "$env:SystemRoot\System32\wscript.exe"
$conhostExe = "$env:SystemRoot\System32\conhost.exe"
$powerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$taskRunnerPath = Join-Path $InstallDirectory 'TaskRunner.ps1'
$taskRunnerVbsPath = Join-Path $InstallDirectory 'TaskRunner.vbs'
$launcherPath = Join-Path $InstallDirectory 'LaunchCodex.ps1'
$wscriptArguments = "//B //Nologo `"$taskRunnerVbsPath`""
$taskArguments = "--headless `"$powerShellExe`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$taskRunnerPath`""
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$userName = $identity.Name

# Create an explicit launcher so Codex has the process proxy from its first
# process and normally never needs the guardian's fallback restart.
$desktopLinkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex (Proxy).lnk'
$codexPackage = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
$launcherArguments = "--headless `"$powerShellExe`" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`""
$shell = New-Object -ComObject WScript.Shell
$launcherShortcut = $shell.CreateShortcut($desktopLinkPath)
$launcherShortcut.TargetPath = $conhostExe
$launcherShortcut.Arguments = $launcherArguments
$launcherShortcut.WorkingDirectory = $InstallDirectory
$launcherShortcut.WindowStyle = 7
$launcherShortcut.Description = 'Start Codex with the validated proxy from the first connection'
if ($codexPackage) {
    $iconPath = Join-Path $codexPackage.InstallLocation 'app\ChatGPT.exe'
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) { $launcherShortcut.IconLocation = "$iconPath,0" }
}
$launcherShortcut.Save()

$startupLinkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'CodexProxyGuardian.lnk'
$runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValue = "`"$wscriptExe`" //B //Nologo `"$taskRunnerVbsPath`""
$registrationMode = 'ScheduledTask'
$taskState = $null
try {
    $action = New-ScheduledTaskAction -Execute $conhostExe -Argument $taskArguments
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
    if ($existing) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue }
    Register-ScheduledTask -TaskName $taskName -InputObject $definition -Force | Out-Null
    Remove-Item -LiteralPath $startupLinkPath -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $runKeyPath -Name 'CodexProxyGuardian' -ErrorAction SilentlyContinue
    if ($StartNow) { Start-ScheduledTask -TaskName $taskName; Start-Sleep -Seconds 2 }
    $taskState = [string](Get-ScheduledTask -TaskName $taskName).State
}
catch {
    # Some managed environments deny the ScheduledTasks CIM provider. A
    # current-user Startup shortcut provides the same silent logon behavior;
    # TaskRunner.vbs supplies retry-on-failure and Guardian supplies the mutex.
    $registrationMode = 'StartupShortcut'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupLinkPath)
    $shortcut.TargetPath = $wscriptExe
    $shortcut.Arguments = $wscriptArguments
    $shortcut.WorkingDirectory = $InstallDirectory
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Codex Proxy Guardian (silent)'
    $shortcut.Save()
    if (-not (Test-Path -LiteralPath $runKeyPath)) { New-Item -Path $runKeyPath -Force | Out-Null }
    Set-ItemProperty -LiteralPath $runKeyPath -Name 'CodexProxyGuardian' -Value $runValue -Type String
    if ($StartNow) {
        Start-Process -FilePath $wscriptExe -ArgumentList @('//B', '//Nologo', "`"$taskRunnerVbsPath`"") -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }
    $taskState = 'StartupShortcutAndRunKeyRegistered'
}

[pscustomobject][ordered]@{
    installed = $true
    installDirectory = $InstallDirectory
    taskName = $taskName
    registrationMode = $registrationMode
    taskState = $taskState
    startNow = [bool]$StartNow
    systemProxyChanged = $false
    winHttpChanged = $false
    environmentChanged = $false
    launcherShortcut = $desktopLinkPath
} | ConvertTo-Json -Depth 4
