# Only retire verified v1 startup entries. Keep the old installation for review.
function Disable-LegacyGuardian {
    param([string]$AdditionalDirectory)
    $candidates = @((Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'), (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'CodexProxyGuardian'))
    if ($AdditionalDirectory) { $candidates += [IO.Path]::GetFullPath($AdditionalDirectory) }
    $roots = @()
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        $markerPath = Join-Path $candidate '.install.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { continue }
        try {
            $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json
            if ($marker.product -eq 'CodexProxyGuardian' -and [string]::Equals([IO.Path]::GetFullPath($marker.installDirectory).TrimEnd('\'),[IO.Path]::GetFullPath($candidate).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
                $roots += [IO.Path]::GetFullPath($candidate).TrimEnd('\')
            }
        }
        catch { throw 'Could not validate a legacy installation marker; no legacy entries were removed.' }
    }
    if ($roots.Count -eq 0) {
        if (Get-ScheduledTask -TaskName 'CodexProxyGuardian' -ErrorAction SilentlyContinue) { throw 'A legacy task exists without a verified install marker; use -LegacyInstallDirectory to identify it.' }
        return [pscustomobject]@{ Migrated=$false; RemovedEntries=0 }
    }
    $count = 0
    foreach ($root in $roots) {
        $pattern = [Regex]::Escape($root) + '\\(?:TaskRunner\.(?:ps1|vbs)|Guardian\.ps1|LaunchCodex\.ps1)(?:"|\s|$)'
        $task = Get-ScheduledTask -TaskName 'CodexProxyGuardian' -ErrorAction SilentlyContinue
        if ($task) {
            $actions = @($task.Actions)
            if ($actions.Count -ne 1 -or $actions[0].Arguments -notmatch $pattern) { throw 'The legacy task does not match the verified installation; retained.' }
            Stop-ScheduledTask -TaskName 'CodexProxyGuardian' -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName 'CodexProxyGuardian' -Confirm:$false
            $count++
        }
        $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='wscript.exe' OR Name='cscript.exe'" -ErrorAction Stop | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $pattern })
        foreach ($process in $processes) { Stop-Process -Id $process.ProcessId -Force; $count++ }
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (Test-Path -LiteralPath $runKey) {
            $properties = (Get-ItemProperty -LiteralPath $runKey).PSObject.Properties
            $property = @($properties | Where-Object { $_.Name -eq 'CodexProxyGuardian' })
            if ($property.Count -eq 1 -and [string]$property[0].Value -match $pattern) { Remove-ItemProperty -LiteralPath $runKey -Name 'CodexProxyGuardian'; $count++ }
        }
        $shell = New-Object -ComObject WScript.Shell
        $links = @((Join-Path ([Environment]::GetFolderPath('Startup')) 'CodexProxyGuardian.lnk'),(Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex (Proxy).lnk'))
        foreach ($path in $links) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $link = $shell.CreateShortcut($path)
                if ([string]$link.Arguments -match $pattern) { Remove-Item -LiteralPath $path -Force; $count++ }
            }
        }
    }
    return [pscustomobject]@{ Migrated=($count -gt 0); RemovedEntries=$count }
}
