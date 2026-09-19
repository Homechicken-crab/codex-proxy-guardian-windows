[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$ResolveOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
}

function Get-ProxyFromConfig {
    param([object]$Config)

    if ([string]$Config.sourceMode -eq 'SpecifiedProxy') {
        return [string]$Config.specifiedProxy
    }

    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ([int]$settings.ProxyEnable -ne 1 -or [string]::IsNullOrWhiteSpace([string]$settings.ProxyServer)) {
        throw 'Windows static system proxy is not enabled.'
    }
    $raw = [string]$settings.ProxyServer
    $scheme = 'http'
    if ($raw.Contains('=')) {
        $map = @{}
        foreach ($part in ($raw -split ';')) {
            if ($part -match '^\s*([^=]+)=(.+)\s*$') { $map[$matches[1].ToLowerInvariant()] = $matches[2] }
        }
        if ($map.ContainsKey('https')) { $raw = [string]$map['https'] }
        elseif ($map.ContainsKey('http')) { $raw = [string]$map['http'] }
        elseif ($map.ContainsKey('socks')) { $raw = [string]$map['socks']; $scheme = 'socks5' }
        elseif ($map.Count -gt 0) { $raw = [string]($map.Values | Select-Object -First 1) }
    }
    if ($raw -notmatch '^[a-z][a-z0-9+.-]*://') { $raw = "${scheme}://$raw" }
    return $raw
}

$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$proxy = Get-ProxyFromConfig -Config $config
$uri = [Uri]$proxy
if ($uri.Scheme -notin @('http', 'socks5', 'socks5h') -or $uri.Port -le 0) {
    throw "Unsupported proxy endpoint: $proxy"
}
if (-not [bool]$config.allowRemoteProxy -and $uri.Host -notin @('localhost', '127.0.0.1', '::1', '[::1]')) {
    throw 'The configured proxy is not a loopback endpoint.'
}

$packageName = if ($config.PSObject.Properties['codexPackageName']) { [string]$config.codexPackageName } else { 'OpenAI.Codex' }
$pkg = Get-AppxPackage -Name $packageName -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pkg) { throw "Codex package is not registered for this Windows user: $packageName" }
$executable = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Codex executable not found: $executable" }

if ($ResolveOnly) {
    [pscustomobject][ordered]@{ executable = $executable; proxy = $uri.AbsoluteUri.TrimEnd('/'); package = $pkg.PackageFullName } | ConvertTo-Json -Depth 3
    exit 0
}

# These variables exist only in this short-lived launcher and are inherited by
# the Codex process tree. No User/Machine environment or Windows proxy is set.
$proxyUrl = $uri.AbsoluteUri.TrimEnd('/')
$noProxy = 'localhost,127.0.0.1,::1'
foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
    [Environment]::SetEnvironmentVariable($name, $proxyUrl, 'Process')
}
foreach ($name in @('NO_PROXY', 'no_proxy')) {
    [Environment]::SetEnvironmentVariable($name, $noProxy, 'Process')
}

Start-Process -FilePath $executable -ArgumentList @("--proxy-server=$proxyUrl") | Out-Null
