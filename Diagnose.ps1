[CmdletBinding()]
param([switch]$Json)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$guardian = Join-Path $PSScriptRoot 'Guardian.ps1'
$onceText = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $guardian -Command Once 2>&1 | Out-String
$once = $null
try { $once = $onceText | ConvertFrom-Json } catch { }

$internet = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
$proxyVariables = foreach ($scope in @('Process', 'User', 'Machine')) {
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($name, $scope)
        if ($null -ne $value) {
            [pscustomobject]@{ scope = $scope; name = $name; present = $true; value = '<redacted>' }
        }
    }
}
$package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
$task = Get-ScheduledTask -TaskName 'CodexProxyGuardian' -ErrorAction SilentlyContinue

$report = [pscustomobject][ordered]@{
    timestamp = [DateTimeOffset]::Now.ToString('o')
    user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    internetSettings = [pscustomobject]@{
        proxyEnable = if ($internet) { $internet.ProxyEnable } else { $null }
        proxyServer = if ($internet) { $internet.ProxyServer } else { $null }
        autoConfigUrlPresent = [bool]($internet -and $internet.AutoConfigURL)
        proxyOverride = if ($internet) { $internet.ProxyOverride } else { $null }
    }
    winHttp = (netsh winhttp show proxy | Out-String).Trim()
    proxyEnvironment = @($proxyVariables)
    liveCheck = $once
    codexPackage = if ($package) { [pscustomobject]@{ name = $package.Name; version = [string]$package.Version; packageFamilyName = $package.PackageFamilyName; installLocation = $package.InstallLocation } } else { $null }
    guardianTask = if ($task) { [pscustomobject]@{ name = $task.TaskName; state = [string]$task.State } } else { $null }
    invariants = [pscustomobject]@{
        changesWinInet = $false
        changesWinHttp = $false
        changesDnsRoutesFirewall = $false
        defaultWritesProxyEnvironment = $false
    }
}

if ($Json) { $report | ConvertTo-Json -Depth 12 }
else { $report | Format-List }
