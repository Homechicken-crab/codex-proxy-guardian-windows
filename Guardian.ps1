[CmdletBinding()]
param(
    [ValidateSet('Run', 'Once', 'Status', 'Stop')]
    [string]$Command = 'Run',
    [string]$ConfigPath = '',
    [switch]$NoRestart
)

# Codex Proxy Guardian
# - Reads proxy state only; never changes WinINET, WinHTTP, PAC, DNS, firewall, or routes.
# - In SystemProxy mode, the Windows proxy is read as the source of truth, validated,
#   and injected only into the Codex process tree when Codex is launched.
# - SpecifiedProxy mode is supported for diagnostics, but is not enabled by default.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
}

$script:ProductVersion = '1.3.0'
$script:StatePath = Join-Path $PSScriptRoot 'state.json'
$script:StateBackupPath = Join-Path $PSScriptRoot 'state.json.bak'
$script:StopRequestPath = Join-Path $PSScriptRoot 'stop.request'
$script:LogDirectory = Join-Path $PSScriptRoot 'logs'
$script:LogPath = Join-Path $script:LogDirectory 'guardian.jsonl'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Config = $null

function Get-PropertyValue {
    param([object]$Object, [string]$Name, $Default)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-PropertyValue $cfg 'schemaVersion' 0) -ne 1) {
        throw 'Unsupported config schemaVersion.'
    }
    if ((Get-PropertyValue $cfg 'sourceMode' '') -notin @('SystemProxy', 'SpecifiedProxy')) {
        throw 'sourceMode must be SystemProxy or SpecifiedProxy.'
    }
    return $cfg
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 12
    $tmp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
        $backup = "$Path.bak"
        try {
            [System.IO.File]::Replace($tmp, $Path, $backup, $true)
        }
        catch {
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
    }
    else {
        Move-Item -LiteralPath $tmp -Destination $Path
    }
}

function Read-State {
    $paths = @($script:StatePath, $script:StateBackupPath)
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                $defaults = [ordered]@{
                    appliedLaunchFingerprint = $null
                    lastWebSocketProbeOk = $false
                    lastWebSocketProbeDetail = $null
                    codexDetectedAt = $null
                }
                foreach ($name in $defaults.Keys) {
                    if ($null -eq $state.PSObject.Properties[$name]) {
                        $state | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name]
                    }
                }
                return $state
            }
            catch { }
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        productVersion = $script:ProductVersion
        pid = 0
        startedAt = $null
        lastHeartbeatAt = $null
        observedProxy = $null
        pendingProxy = $null
        pendingSince = $null
        pendingCount = 0
        appliedProxy = $null
        lastKnownGoodProxy = $null
        lastProbeAt = $null
        lastProbeOk = $false
        lastProbeDetail = $null
        lastWebSocketProbeOk = $false
        lastWebSocketProbeDetail = $null
        outageSince = $null
        lastRestartAt = $null
        lastRestartAttemptAt = $null
        restartHistory = @()
        circuitOpenUntil = $null
        lastAction = 'created'
        lastError = $null
        codexWasRunning = $false
        codexDetectedAt = $null
        trafficVerified = $false
        appliedLaunchFingerprint = $null
    }
}

function Save-State {
    param([object]$State)
    Write-JsonAtomic -Path $script:StatePath -Value $State
}

function Rotate-LogIfNeeded {
    if (-not (Test-Path -LiteralPath $script:LogPath)) { return }
    $maxBytes = [int64](Get-PropertyValue $script:Config 'logMaxBytes' 5242880)
    $keep = [int](Get-PropertyValue $script:Config 'logFiles' 5)
    if ((Get-Item -LiteralPath $script:LogPath).Length -lt $maxBytes) { return }
    for ($i = $keep - 1; $i -ge 1; $i--) {
        $source = if ($i -eq 1) { $script:LogPath } else { "$($script:LogPath).$($i - 1)" }
        $destination = "$($script:LogPath).$i"
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination $destination -Force
        }
    }
}

function Write-GuardianLog {
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$Event,
        [string]$Message,
        [object]$Data = $null
    )
    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
            New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
        }
        Rotate-LogIfNeeded
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            level = $Level
            event = $Event
            message = $Message
        }
        if ($null -ne $Data) { $entry.data = $Data }
        $line = ([pscustomobject]$entry | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine
        [System.IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8NoBom)
    }
    catch { }
}

function Test-IsLoopbackHost {
    param([string]$HostName)
    if ($HostName -in @('localhost', '127.0.0.1', '::1', '[::1]')) { return $true }
    $address = $null
    if ([System.Net.IPAddress]::TryParse($HostName.Trim('[', ']'), [ref]$address)) {
        return [System.Net.IPAddress]::IsLoopback($address)
    }
    return $false
}

function ConvertTo-ProxyEndpoint {
    param(
        [string]$Value,
        [string]$DefaultScheme = 'http',
        [string]$Source = 'unknown'
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    if ($text -match '[\r\n]') { throw 'Proxy value contains a newline.' }

    if ($text.Contains('=') -or $text.Contains(';')) {
        $map = @{}
        foreach ($piece in ($text -split ';')) {
            $trimmed = $piece.Trim()
            if (-not $trimmed) { continue }
            if ($trimmed -match '^([^=]+)=(.+)$') {
                $map[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
            }
            elseif (-not $map.ContainsKey('default')) {
                $map['default'] = $trimmed
            }
        }
        foreach ($key in @('https', 'http', 'socks', 'default')) {
            if ($map.ContainsKey($key)) {
                $DefaultScheme = if ($key -eq 'socks') { 'socks5' } else { 'http' }
                $text = [string]$map[$key]
                break
            }
        }
    }

    if ($text -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') {
        $text = "$DefaultScheme`://$text"
    }
    $uri = $null
    if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)) {
        throw 'Proxy endpoint is not a valid URI.'
    }
    $scheme = $uri.Scheme.ToLowerInvariant()
    if ($scheme -eq 'socks') { $scheme = 'socks5' }
    if ($scheme -notin @('http', 'socks5', 'socks5h')) {
        throw "Unsupported proxy scheme: $scheme"
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw 'Credential-bearing proxy URIs are not accepted.'
    }
    if ($uri.AbsolutePath -notin @('', '/')) {
        throw 'Proxy URI must not contain a path.'
    }
    if ($uri.Query -or $uri.Fragment) {
        throw 'Proxy URI must not contain a query or fragment.'
    }
    if ($uri.Port -lt 1 -or $uri.Port -gt 65535) {
        throw 'Proxy port is outside 1-65535.'
    }
    $allowRemote = [bool](Get-PropertyValue $script:Config 'allowRemoteProxy' $false)
    if (-not $allowRemote -and -not (Test-IsLoopbackHost $uri.Host)) {
        throw 'Remote proxy endpoints are disabled; only loopback is allowed.'
    }
    $displayHost = if ($uri.Host.Contains(':')) { "[$($uri.Host)]" } else { $uri.Host }
    return [pscustomobject][ordered]@{
        key = "$scheme`://$displayHost`:$($uri.Port)"
        scheme = $scheme
        host = $uri.Host
        port = $uri.Port
        source = $Source
        ownerPid = $null
        ownerProcess = $null
    }
}

function Get-ListenerOwner {
    param([object]$Endpoint)
    if (-not (Test-IsLoopbackHost ([string]$Endpoint.host))) { return $Endpoint }
    try {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$Endpoint.port) -ErrorAction Stop)
        if ($listeners.Count -eq 0) { return $Endpoint }
        $listener = $listeners | Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') } | Select-Object -First 1
        if ($null -eq $listener) { $listener = $listeners | Select-Object -First 1 }
        $Endpoint.ownerPid = [int]$listener.OwningProcess
        try {
            $Endpoint.ownerProcess = (Get-Process -Id $Endpoint.ownerPid -ErrorAction Stop).ProcessName
        }
        catch { }
    }
    catch { }
    return $Endpoint
}

function Get-DesiredProxy {
    $mode = [string](Get-PropertyValue $script:Config 'sourceMode' 'SystemProxy')
    if ($mode -eq 'SpecifiedProxy') {
        return (Get-ListenerOwner (ConvertTo-ProxyEndpoint -Value ([string](Get-PropertyValue $script:Config 'specifiedProxy' '')) -Source 'specified'))
    }

    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    if ([int](Get-PropertyValue $settings 'ProxyEnable' 0) -ne 1) {
        $pac = [string](Get-PropertyValue $settings 'AutoConfigURL' '')
        if ($pac) { throw 'A PAC URL is active; a single safe static endpoint cannot be inferred.' }
        return $null
    }
    $raw = [string](Get-PropertyValue $settings 'ProxyServer' '')
    return (Get-ListenerOwner (ConvertTo-ProxyEndpoint -Value $raw -DefaultScheme 'http' -Source 'wininet'))
}

function Connect-TcpWithTimeout {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            throw "TCP connect timed out after $TimeoutMs ms"
        }
        $client.EndConnect($async)
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        return $client
    }
    catch {
        $client.Dispose()
        throw
    }
}

function Read-ExactBytes {
    param([System.IO.Stream]$Stream, [int]$Count)
    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { throw 'Unexpected end of proxy response.' }
        $offset += $read
    }
    return $buffer
}

function Test-HttpConnectProxy {
    param([object]$Endpoint, [string]$TargetHost, [int]$TargetPort, [int]$TimeoutMs)
    $client = Connect-TcpWithTimeout -HostName $Endpoint.host -Port $Endpoint.port -TimeoutMs $TimeoutMs
    try {
        $stream = $client.GetStream()
        $request = "CONNECT $TargetHost`:$TargetPort HTTP/1.1`r`nHost: $TargetHost`:$TargetPort`r`nProxy-Connection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $buffer = New-Object byte[] 512
        $count = $stream.Read($buffer, 0, $buffer.Length)
        $response = [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
        $firstLine = ($response -split "`r?`n")[0]
        if ($firstLine -notmatch '^HTTP/\S+\s+(\d{3})') {
            throw "Unexpected HTTP proxy response: $firstLine"
        }
        $status = [int]$matches[1]
        if ($status -lt 200 -or $status -ge 300) {
            throw "HTTP CONNECT returned $status"
        }
        return "HTTP CONNECT $status"
    }
    finally { $client.Dispose() }
}

function Test-Socks5Proxy {
    param([object]$Endpoint, [string]$TargetHost, [int]$TargetPort, [int]$TimeoutMs)
    $client = Connect-TcpWithTimeout -HostName $Endpoint.host -Port $Endpoint.port -TimeoutMs $TimeoutMs
    try {
        $stream = $client.GetStream()
        $stream.Write([byte[]](5, 1, 0), 0, 3)
        $hello = Read-ExactBytes -Stream $stream -Count 2
        if ($hello[0] -ne 5 -or $hello[1] -ne 0) { throw 'SOCKS5 proxy rejected no-auth negotiation.' }
        $hostBytes = [Text.Encoding]::ASCII.GetBytes($TargetHost)
        if ($hostBytes.Length -gt 255) { throw 'SOCKS5 target hostname is too long.' }
        $request = New-Object byte[] (7 + $hostBytes.Length)
        $request[0] = 5; $request[1] = 1; $request[2] = 0; $request[3] = 3
        $request[4] = [byte]$hostBytes.Length
        [Array]::Copy($hostBytes, 0, $request, 5, $hostBytes.Length)
        $request[5 + $hostBytes.Length] = [byte](($TargetPort -shr 8) -band 255)
        $request[6 + $hostBytes.Length] = [byte]($TargetPort -band 255)
        $stream.Write($request, 0, $request.Length)
        $reply = Read-ExactBytes -Stream $stream -Count 4
        if ($reply[0] -ne 5 -or $reply[1] -ne 0) { throw "SOCKS5 CONNECT returned code $($reply[1])." }
        switch ($reply[3]) {
            1 { [void](Read-ExactBytes -Stream $stream -Count 6) }
            3 { $length = (Read-ExactBytes -Stream $stream -Count 1)[0]; [void](Read-ExactBytes -Stream $stream -Count ($length + 2)) }
            4 { [void](Read-ExactBytes -Stream $stream -Count 18) }
            default { throw 'SOCKS5 proxy returned an invalid address type.' }
        }
        return 'SOCKS5 CONNECT 0'
    }
    finally { $client.Dispose() }
}

function Open-ProxyTunnel {
    param([object]$Endpoint, [string]$TargetHost, [int]$TargetPort, [int]$TimeoutMs)
    $client = Connect-TcpWithTimeout -HostName $Endpoint.host -Port $Endpoint.port -TimeoutMs $TimeoutMs
    try {
        $stream = $client.GetStream()
        if ($Endpoint.scheme -eq 'http') {
            $request = "CONNECT $TargetHost`:$TargetPort HTTP/1.1`r`nHost: $TargetHost`:$TargetPort`r`nProxy-Connection: keep-alive`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($request)
            $stream.Write($bytes, 0, $bytes.Length)
            $headerBytes = New-Object 'System.Collections.Generic.List[byte]'
            while ($headerBytes.Count -lt 16384) {
                $value = $stream.ReadByte()
                if ($value -lt 0) { throw 'Unexpected end of HTTP CONNECT response.' }
                $headerBytes.Add([byte]$value)
                $count = $headerBytes.Count
                if ($count -ge 4 -and $headerBytes[$count - 4] -eq 13 -and $headerBytes[$count - 3] -eq 10 -and $headerBytes[$count - 2] -eq 13 -and $headerBytes[$count - 1] -eq 10) { break }
            }
            $response = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
            $firstLine = ($response -split "`r?`n")[0]
            if ($firstLine -notmatch '^HTTP/\S+\s+(\d{3})') { throw "Unexpected HTTP proxy response: $firstLine" }
            $status = [int]$matches[1]
            if ($status -lt 200 -or $status -ge 300) { throw "HTTP CONNECT returned $status" }
        }
        else {
            $stream.Write([byte[]](5, 1, 0), 0, 3)
            $hello = Read-ExactBytes -Stream $stream -Count 2
            if ($hello[0] -ne 5 -or $hello[1] -ne 0) { throw 'SOCKS5 proxy rejected no-auth negotiation.' }
            $hostBytes = [Text.Encoding]::ASCII.GetBytes($TargetHost)
            if ($hostBytes.Length -gt 255) { throw 'SOCKS5 target hostname is too long.' }
            $request = New-Object byte[] (7 + $hostBytes.Length)
            $request[0] = 5; $request[1] = 1; $request[2] = 0; $request[3] = 3
            $request[4] = [byte]$hostBytes.Length
            [Array]::Copy($hostBytes, 0, $request, 5, $hostBytes.Length)
            $request[5 + $hostBytes.Length] = [byte](($TargetPort -shr 8) -band 255)
            $request[6 + $hostBytes.Length] = [byte]($TargetPort -band 255)
            $stream.Write($request, 0, $request.Length)
            $reply = Read-ExactBytes -Stream $stream -Count 4
            if ($reply[0] -ne 5 -or $reply[1] -ne 0) { throw "SOCKS5 CONNECT returned code $($reply[1])." }
            switch ($reply[3]) {
                1 { [void](Read-ExactBytes -Stream $stream -Count 6) }
                3 { $length = (Read-ExactBytes -Stream $stream -Count 1)[0]; [void](Read-ExactBytes -Stream $stream -Count ($length + 2)) }
                4 { [void](Read-ExactBytes -Stream $stream -Count 18) }
                default { throw 'SOCKS5 proxy returned an invalid address type.' }
            }
        }
        return $client
    }
    catch {
        $client.Dispose()
        throw
    }
}

function Test-WebSocketUpgradeProxy {
    param([object]$Endpoint)
    $hostName = [string](Get-PropertyValue $script:Config 'webSocketProbeHost' 'chatgpt.com')
    $path = [string](Get-PropertyValue $script:Config 'webSocketProbePath' '/backend-api/codex/responses')
    $timeout = [int](Get-PropertyValue $script:Config 'webSocketProbeTimeoutMs' 8000)
    $client = Open-ProxyTunnel -Endpoint $Endpoint -TargetHost $hostName -TargetPort 443 -TimeoutMs $timeout
    $ssl = $null
    try {
        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
        $ssl.ReadTimeout = $timeout
        $ssl.WriteTimeout = $timeout
        $ssl.AuthenticateAsClient($hostName)
        $key = [Convert]::ToBase64String((([Guid]::NewGuid()).ToByteArray()))
        $request = "GET $path HTTP/1.1`r`nHost: $hostName`r`nConnection: Upgrade`r`nUpgrade: websocket`r`nSec-WebSocket-Version: 13`r`nSec-WebSocket-Key: $key`r`nOrigin: https://$hostName`r`nUser-Agent: CodexProxyGuardian/$($script:ProductVersion)`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $ssl.Write($bytes, 0, $bytes.Length)
        $ssl.Flush()
        $buffer = New-Object byte[] 4096
        $count = $ssl.Read($buffer, 0, $buffer.Length)
        if ($count -le 0) { throw 'WebSocket upgrade returned no HTTP response.' }
        $response = [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
        $firstLine = ($response -split "`r?`n")[0]
        if ($firstLine -notmatch '^HTTP/\S+\s+\d{3}\b') { throw "Unexpected WebSocket upgrade response: $firstLine" }
        return "WSS route reachable ($firstLine)"
    }
    finally {
        if ($null -ne $ssl) { $ssl.Dispose() }
        $client.Dispose()
    }
}

function Test-ProxyEndpoint {
    param([object]$Endpoint)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $targetHost = [string](Get-PropertyValue $script:Config 'probeHost' 'api.openai.com')
        $targetPort = [int](Get-PropertyValue $script:Config 'probePort' 443)
        $timeout = [int](Get-PropertyValue $script:Config 'probeTimeoutMs' 6000)
        $detail = if ($Endpoint.scheme -eq 'http') {
            Test-HttpConnectProxy -Endpoint $Endpoint -TargetHost $targetHost -TargetPort $targetPort -TimeoutMs $timeout
        }
        else {
            Test-Socks5Proxy -Endpoint $Endpoint -TargetHost $targetHost -TargetPort $targetPort -TimeoutMs $timeout
        }
        $wsOk = $null
        $wsDetail = $null
        if ([bool](Get-PropertyValue $script:Config 'webSocketProbeEnabled' $true)) {
            $wsDetail = Test-WebSocketUpgradeProxy -Endpoint $Endpoint
            $wsOk = $true
            $detail = "$detail; $wsDetail"
        }
        return [pscustomobject]@{ ok = $true; detail = $detail; elapsedMs = $watch.ElapsedMilliseconds; webSocketOk = $wsOk; webSocketDetail = $wsDetail }
    }
    catch {
        return [pscustomobject]@{ ok = $false; detail = $_.Exception.GetBaseException().Message; elapsedMs = $watch.ElapsedMilliseconds; webSocketOk = $false; webSocketDetail = $_.Exception.GetBaseException().Message }
    }
}

function Get-CodexInstallInfo {
    $packageName = [string](Get-PropertyValue $script:Config 'codexPackageName' 'OpenAI.Codex')
    $pkg = Get-AppxPackage -Name $packageName -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
    $exe = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Codex executable not found: $exe" }
    return [pscustomobject]@{
        packageFullName = $pkg.PackageFullName
        packageFamilyName = $pkg.PackageFamilyName
        installLocation = $pkg.InstallLocation
        executable = $exe
        aumid = [string](Get-PropertyValue $script:Config 'codexAumid' "$($pkg.PackageFamilyName)!App")
    }
}

function Get-CodexProcessSnapshot {
    $install = $null
    try { $install = Get-CodexInstallInfo } catch { return @() }
    $expected = [IO.Path]::GetFullPath($install.executable)
    $all = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue)
    $matches = @()
    foreach ($item in $all) {
        $path = [string]$item.ExecutablePath
        if (-not $path) {
            try { $path = (Get-Process -Id $item.ProcessId -ErrorAction Stop).Path } catch { }
        }
        if ($path -and [string]::Equals([IO.Path]::GetFullPath($path), $expected, [StringComparison]::OrdinalIgnoreCase)) {
            $matches += [pscustomobject]@{
                processId = [int]$item.ProcessId
                parentProcessId = [int]$item.ParentProcessId
                commandLine = [string]$item.CommandLine
                executablePath = $path
            }
        }
    }
    return @($matches)
}

function Get-CodexRootProcesses {
    $items = @(Get-CodexProcessSnapshot)
    if ($items.Count -eq 0) { return @() }
    $ids = @($items | ForEach-Object { $_.processId })
    return @($items | Where-Object { $_.parentProcessId -notin $ids -and $_.commandLine -notmatch '(?:^|\s)--type=' })
}

function Stop-CodexSafely {
    $roots = @(Get-CodexRootProcesses)
    if ($roots.Count -eq 0) { return $true }
    Write-GuardianLog INFO 'codex.stop.begin' 'Requesting a graceful Codex shutdown.' @{ rootPids = @($roots.processId) }
    foreach ($root in $roots) {
        try { [void](Get-Process -Id $root.processId -ErrorAction Stop).CloseMainWindow() } catch { }
    }
    $deadline = [DateTimeOffset]::Now.AddSeconds([int](Get-PropertyValue $script:Config 'gracefulCloseSeconds' 15))
    while ([DateTimeOffset]::Now -lt $deadline) {
        if (@(Get-CodexProcessSnapshot).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }

    # Re-resolve and verify exact package path immediately before forced termination.
    $remainingRoots = @(Get-CodexRootProcesses)
    foreach ($root in $remainingRoots) {
        Write-GuardianLog WARN 'codex.stop.force' 'Graceful shutdown timed out; terminating the verified Codex process tree.' @{ rootPid = $root.processId }
        & "$env:SystemRoot\System32\taskkill.exe" /PID $root.processId /T /F | Out-Null
    }
    Start-Sleep -Seconds 2
    return (@(Get-CodexProcessSnapshot).Count -eq 0)
}

function Start-Codex {
    param([object]$Endpoint)
    $install = Get-CodexInstallInfo
    $mode = [string](Get-PropertyValue $script:Config 'sourceMode' 'SystemProxy')
    $inject = [bool](Get-PropertyValue $script:Config 'injectProcessProxy' $true)
    if ($mode -eq 'SystemProxy' -and -not $inject) {
        Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList @("shell:AppsFolder\$($install.aumid)") | Out-Null
        return
    }

    # Launch with an explicit process-only proxy so both Chromium and the native
    # codex.exe child use the same route. No User or Machine environment is changed.
    $names = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $url = [string]$Endpoint.key
        $noProxy = 'localhost,127.0.0.1,::1'
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
            [Environment]::SetEnvironmentVariable($name, $url, 'Process')
        }
        foreach ($name in @('NO_PROXY', 'no_proxy')) {
            [Environment]::SetEnvironmentVariable($name, $noProxy, 'Process')
        }
        Start-Process -FilePath $install.executable -ArgumentList @("--proxy-server=$url") | Out-Null
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

function Get-CodexLaunchFingerprint {
    param([object]$Endpoint)
    $inject = [bool](Get-PropertyValue $script:Config 'injectProcessProxy' $true)
    $kind = if ($inject) { 'explicit-process-proxy-v1' } else { 'system-proxy-v1' }
    return "$kind|$($Endpoint.key)"
}

function Test-CodexUsesProxy {
    param([object]$Endpoint)
    try {
        $pids = @(Get-CodexProcessSnapshot | ForEach-Object { $_.processId })
        if ($pids.Count -eq 0) { return $false }
        $connections = @(Get-NetTCPConnection -State Established -RemotePort ([int]$Endpoint.port) -ErrorAction Stop |
            Where-Object { $_.OwningProcess -in $pids })
        foreach ($connection in $connections) {
            if ($connection.RemoteAddress -eq $Endpoint.host) { return $true }
            if ((Test-IsLoopbackHost $Endpoint.host) -and (Test-IsLoopbackHost $connection.RemoteAddress)) { return $true }
        }
    }
    catch { }
    return $false
}

function Test-CodexLaunchHasProxy {
    param([object]$Endpoint)
    $argument = "--proxy-server=$($Endpoint.key)"
    foreach ($process in @(Get-CodexRootProcesses)) {
        if ([string]$process.commandLine -and [string]$process.commandLine.IndexOf($argument, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Restart-CodexForProxy {
    param([object]$Endpoint)
    $wasRunning = @(Get-CodexRootProcesses).Count -gt 0
    if (-not $wasRunning -and -not [bool](Get-PropertyValue $script:Config 'ensureCodexRunning' $false)) {
        return [pscustomobject]@{ success = $true; wasRunning = $false; started = $false; trafficVerified = $false; detail = 'Codex was not running; no launch requested.' }
    }
    if ($NoRestart) {
        return [pscustomobject]@{ success = $true; wasRunning = $wasRunning; started = $false; trafficVerified = $false; detail = 'Restart suppressed by -NoRestart.' }
    }
    $finalProbe = Test-ProxyEndpoint -Endpoint $Endpoint
    if (-not $finalProbe.ok) {
        return [pscustomobject]@{ success = $false; wasRunning = $wasRunning; started = $false; trafficVerified = $false; detail = "Final proxy probe failed: $($finalProbe.detail)" }
    }
    if ($wasRunning -and -not (Stop-CodexSafely)) {
        return [pscustomobject]@{ success = $false; wasRunning = $true; started = $false; trafficVerified = $false; detail = 'Verified Codex process did not stop.' }
    }
    Start-Codex -Endpoint $Endpoint
    $deadline = [DateTimeOffset]::Now.AddSeconds([int](Get-PropertyValue $script:Config 'startupVerifySeconds' 35))
    $seenProcess = $false
    $traffic = $false
    while ([DateTimeOffset]::Now -lt $deadline) {
        if (@(Get-CodexRootProcesses).Count -gt 0) { $seenProcess = $true }
        if ($seenProcess -and (Test-CodexUsesProxy -Endpoint $Endpoint)) { $traffic = $true; break }
        Start-Sleep -Seconds 1
    }
    return [pscustomobject]@{
        success = $seenProcess
        wasRunning = $wasRunning
        started = $seenProcess
        trafficVerified = $traffic
        detail = if (-not $seenProcess) { 'Codex did not remain running.' } elseif ($traffic) { 'Codex traffic observed on the validated endpoint.' } else { 'Codex started; no proxy connection was observed within the verification window.' }
    }
}

function Test-RestartAllowed {
    param([object]$State, [DateTimeOffset]$Now)
    if ($State.circuitOpenUntil) {
        $until = [DateTimeOffset]::Parse([string]$State.circuitOpenUntil)
        if ($Now -lt $until) { return $false }
        $State.circuitOpenUntil = $null
    }
    if ($State.lastRestartAttemptAt) {
        $last = [DateTimeOffset]::Parse([string]$State.lastRestartAttemptAt)
        if (($Now - $last).TotalSeconds -lt [int](Get-PropertyValue $script:Config 'restartCooldownSeconds' 120)) { return $false }
    }
    $window = [int](Get-PropertyValue $script:Config 'restartWindowSeconds' 600)
    $history = @($State.restartHistory | Where-Object { ($Now - [DateTimeOffset]::Parse([string]$_)).TotalSeconds -le $window })
    $State.restartHistory = $history
    if ($history.Count -ge [int](Get-PropertyValue $script:Config 'maxRestartsInWindow' 2)) {
        $State.circuitOpenUntil = $Now.AddSeconds([int](Get-PropertyValue $script:Config 'circuitBreakSeconds' 900)).ToString('o')
        Write-GuardianLog ERROR 'restart.circuit-open' 'Restart rate limit reached; opening circuit breaker.' @{ until = $State.circuitOpenUntil }
        return $false
    }
    return $true
}

function Invoke-ApplyProxy {
    param([object]$State, [object]$Endpoint, [string]$Reason)
    $now = [DateTimeOffset]::Now
    if (-not (Test-RestartAllowed -State $State -Now $now)) {
        $State.lastAction = 'restart-suppressed'
        return $false
    }
    $willAttemptRestart = (@(Get-CodexRootProcesses).Count -gt 0 -or [bool](Get-PropertyValue $script:Config 'ensureCodexRunning' $false)) -and -not $NoRestart
    if ($willAttemptRestart) {
        $State.lastRestartAttemptAt = $now.ToString('o')
        $State.restartHistory = @($State.restartHistory) + @($now.ToString('o'))
    }
    Write-GuardianLog INFO 'proxy.apply.begin' 'Applying a validated proxy transition to Codex.' @{ endpoint = $Endpoint.key; reason = $Reason; ownerPid = $Endpoint.ownerPid; ownerProcess = $Endpoint.ownerProcess }
    $result = Restart-CodexForProxy -Endpoint $Endpoint
    $State.codexWasRunning = [bool]$result.wasRunning
    $State.trafficVerified = [bool]$result.trafficVerified
    if ($result.success) {
        $State.appliedProxy = $Endpoint.key
        $State.lastKnownGoodProxy = $Endpoint.key
        if ($result.started) {
            $State | Add-Member -NotePropertyName appliedLaunchFingerprint -NotePropertyValue (Get-CodexLaunchFingerprint -Endpoint $Endpoint) -Force
        }
        $State.lastRestartAt = if ($result.wasRunning -or $result.started) { $now.ToString('o') } else { $State.lastRestartAt }
        $State.lastAction = 'applied'
        $State.lastError = $null
        Write-GuardianLog INFO 'proxy.apply.success' ([string]$result.detail) @{ endpoint = $Endpoint.key; trafficVerified = $result.trafficVerified; restarted = $result.wasRunning }
        return $true
    }
    $State.lastAction = 'apply-failed'
    $State.lastError = [string]$result.detail
    Write-GuardianLog ERROR 'proxy.apply.failed' ([string]$result.detail) @{ endpoint = $Endpoint.key }
    return $false
}

function Invoke-Observation {
    param([object]$State)
    $now = [DateTimeOffset]::Now
    $changed = $false
    $codexRunning = @(Get-CodexRootProcesses).Count -gt 0
    $endpoint = $null
    $probe = $null
    try {
        $endpoint = Get-DesiredProxy
        if ($null -ne $endpoint) { $probe = Test-ProxyEndpoint -Endpoint $endpoint }
    }
    catch {
        $probe = [pscustomobject]@{ ok = $false; detail = $_.Exception.GetBaseException().Message; elapsedMs = 0 }
    }

    $State.lastProbeAt = $now.ToString('o')
    $State.lastProbeOk = ($null -ne $endpoint -and $null -ne $probe -and [bool]$probe.ok)
    $State.lastProbeDetail = if ($null -ne $probe) { [string]$probe.detail } else { 'No proxy is enabled.' }
    $State.lastWebSocketProbeOk = ($null -ne $probe -and [bool](Get-PropertyValue $probe 'webSocketOk' $false))
    $State.lastWebSocketProbeDetail = if ($null -ne $probe) { [string](Get-PropertyValue $probe 'webSocketDetail' $null) } else { $null }
    $observedKey = if ($null -ne $endpoint) { [string]$endpoint.key } else { $null }
    if ($State.observedProxy -ne $observedKey) {
        $State.observedProxy = $observedKey
        $changed = $true
        Write-GuardianLog INFO 'proxy.observed' 'Observed proxy candidate changed.' @{ endpoint = $observedKey; source = if ($endpoint) { $endpoint.source } else { $null }; ownerPid = if ($endpoint) { $endpoint.ownerPid } else { $null }; ownerProcess = if ($endpoint) { $endpoint.ownerProcess } else { $null } }
    }

    if (-not $State.lastProbeOk) {
        if (-not $State.outageSince) {
            $State.outageSince = $now.ToString('o')
            Write-GuardianLog WARN 'proxy.unavailable' 'No validated proxy is currently available; keeping last-known-good state and not restarting Codex.' @{ endpoint = $observedKey; detail = $State.lastProbeDetail }
        }
        $State.pendingProxy = $null
        $State.pendingSince = $null
        $State.pendingCount = 0
        $State.lastAction = 'waiting-for-valid-proxy'
        return $true
    }

    if ($State.pendingProxy -ne $endpoint.key) {
        $State.pendingProxy = $endpoint.key
        $State.pendingSince = $now.ToString('o')
        $State.pendingCount = 1
        $changed = $true
    }
    else {
        $State.pendingCount = [int]$State.pendingCount + 1
    }

    $stableFor = ($now - [DateTimeOffset]::Parse([string]$State.pendingSince)).TotalSeconds
    $stable = ([int]$State.pendingCount -ge [int](Get-PropertyValue $script:Config 'stableChecks' 3)) -and
              ($stableFor -ge [int](Get-PropertyValue $script:Config 'debounceSeconds' 15))
    if (-not $stable) {
        $State.lastAction = 'debouncing'
        return $true
    }

    # A Codex instance launched through LaunchCodex.ps1 already has the proxy
    # from its first process. Give it time to make its first connection and
    # adopt it without interruption. A normal Start-menu launch remains
    # protected by the existing one-time fallback restart after this window.
    if ($codexRunning -and -not [bool]$State.codexWasRunning) {
        if (-not $State.codexDetectedAt) {
            $State.codexDetectedAt = $now.ToString('o')
            $State.lastAction = 'verifying-new-codex'
            Write-GuardianLog INFO 'codex.detected' 'Codex started; waiting briefly for proxy traffic before considering a fallback restart.' @{ endpoint = $endpoint.key }
            return $true
        }
        $launchHasProxy = Test-CodexLaunchHasProxy -Endpoint $endpoint
        $trafficObserved = Test-CodexUsesProxy -Endpoint $endpoint
        if ($launchHasProxy -or $trafficObserved) {
            $State.appliedProxy = $endpoint.key
            $State.lastKnownGoodProxy = $endpoint.key
            $State.trafficVerified = $trafficObserved
            $State.codexWasRunning = $true
            $State.codexDetectedAt = $null
            $State | Add-Member -NotePropertyName appliedLaunchFingerprint -NotePropertyValue (Get-CodexLaunchFingerprint -Endpoint $endpoint) -Force
            $State.lastAction = 'codex-already-proxied'
            $State.lastError = $null
            Write-GuardianLog INFO 'codex.proxy-present' 'Codex already has the validated proxy; no restart is needed.' @{ endpoint = $endpoint.key; launchArgument = $launchHasProxy; trafficObserved = $trafficObserved }
            return $true
        }
        $detectedFor = ($now - [DateTimeOffset]::Parse([string]$State.codexDetectedAt)).TotalSeconds
        if ($detectedFor -lt [int](Get-PropertyValue $script:Config 'codexLaunchGraceSeconds' 20)) {
            $State.lastAction = 'verifying-new-codex'
            return $true
        }
        $State.codexDetectedAt = $null
    }
    elseif (-not $codexRunning) {
        $State.codexWasRunning = $false
        $State.codexDetectedAt = $null
    }

    $outageDuration = 0
    if ($State.outageSince) { $outageDuration = ($now - [DateTimeOffset]::Parse([string]$State.outageSince)).TotalSeconds }
    $recovered = $State.outageSince -and
        $outageDuration -ge [int](Get-PropertyValue $script:Config 'failureGraceSeconds' 60)
    $desiredLaunchFingerprint = Get-CodexLaunchFingerprint -Endpoint $endpoint
    $appliedLaunchFingerprint = [string](Get-PropertyValue $State 'appliedLaunchFingerprint' '')

    if (-not $State.appliedProxy) {
        if ([bool](Get-PropertyValue $script:Config 'injectProcessProxy' $true)) {
            [void](Invoke-ApplyProxy -State $State -Endpoint $endpoint -Reason 'bootstrap-process-proxy')
        }
        else {
            $State.appliedProxy = $endpoint.key
            $State.lastKnownGoodProxy = $endpoint.key
            $State.trafficVerified = Test-CodexUsesProxy -Endpoint $endpoint
            $State | Add-Member -NotePropertyName appliedLaunchFingerprint -NotePropertyValue $desiredLaunchFingerprint -Force
            $State.lastAction = 'bootstrapped'
            Write-GuardianLog INFO 'proxy.bootstrap' 'Recorded the initial validated proxy without restarting Codex.' @{ endpoint = $endpoint.key; trafficVerified = $State.trafficVerified }
        }
        $changed = $true
    }
    elseif ($State.appliedProxy -ne $endpoint.key) {
        [void](Invoke-ApplyProxy -State $State -Endpoint $endpoint -Reason 'endpoint-changed')
        $changed = $true
    }
    elseif ($appliedLaunchFingerprint -ne $desiredLaunchFingerprint) {
        if ($codexRunning -or [bool](Get-PropertyValue $script:Config 'ensureCodexRunning' $false)) {
            [void](Invoke-ApplyProxy -State $State -Endpoint $endpoint -Reason 'launch-proxy-profile-changed')
        }
        else {
            $State.lastAction = 'waiting-for-codex-start'
        }
        $changed = $true
    }
    elseif ($codexRunning -and -not [bool]$State.codexWasRunning) {
        # No proxy traffic appeared during the launch grace period. This is
        # normally a launch through the stock shortcut, so use one controlled
        # fallback restart with the explicit process proxy.
        [void](Invoke-ApplyProxy -State $State -Endpoint $endpoint -Reason 'codex-start-detected')
        $changed = $true
    }
    elseif ($recovered) {
        # The endpoint did not change, so the running process still has the
        # correct proxy environment and Chromium argument. Recovery needs no
        # restart unless the operator explicitly retains the legacy behavior.
        if ([bool](Get-PropertyValue $script:Config 'restartAfterRecovery' $false)) {
            [void](Invoke-ApplyProxy -State $State -Endpoint $endpoint -Reason 'proxy-recovered-after-outage')
        }
        else {
            $State.lastKnownGoodProxy = $endpoint.key
            $State.codexWasRunning = $codexRunning
            $State.lastAction = 'proxy-recovered-no-restart'
            Write-GuardianLog INFO 'proxy.recovered' 'The same proxy endpoint recovered; Codex was left running.' @{ endpoint = $endpoint.key }
        }
        $changed = $true
    }
    else {
        $State.lastKnownGoodProxy = $endpoint.key
        $State.codexWasRunning = $codexRunning
        $State.lastAction = 'healthy'
    }
    $State.outageSince = $null
    return $changed
}

function Get-MutexName {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid))
        $token = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
    }
    finally { $sha.Dispose() }
    return "Local\CodexProxyGuardian-$token"
}

function Get-StatusObject {
    $state = Read-State
    $task = $null
    try {
        $taskInfo = Get-ScheduledTask -TaskName 'CodexProxyGuardian' -ErrorAction Stop
        $taskRuntime = Get-ScheduledTaskInfo -TaskName 'CodexProxyGuardian' -ErrorAction Stop
        $task = [pscustomobject]@{ state = [string]$taskInfo.State; lastRunTime = $taskRuntime.LastRunTime; lastTaskResult = $taskRuntime.LastTaskResult; nextRunTime = $taskRuntime.NextRunTime }
    }
    catch { }
    $current = $null
    $probe = $null
    try { $current = Get-DesiredProxy; if ($current) { $probe = Test-ProxyEndpoint -Endpoint $current } } catch { $probe = [pscustomobject]@{ ok = $false; detail = $_.Exception.GetBaseException().Message; elapsedMs = 0 } }
    return [pscustomobject][ordered]@{
        productVersion = $script:ProductVersion
        task = $task
        guardianPid = $state.pid
        state = $state
        currentProxy = $current
        currentProbe = $probe
        codexRoots = @(Get-CodexRootProcesses)
        logPath = $script:LogPath
    }
}

$script:Config = Read-Config

if ($Command -eq 'Status') {
    Get-StatusObject | ConvertTo-Json -Depth 12
    exit 0
}

if ($Command -eq 'Stop') {
    [System.IO.File]::WriteAllText($script:StopRequestPath, [DateTimeOffset]::Now.ToString('o'), $script:Utf8NoBom)
    Write-Output 'Stop requested.'
    exit 0
}

if ($Command -eq 'Once') {
    $endpoint = $null
    try { $endpoint = Get-DesiredProxy } catch { [pscustomobject]@{ endpoint = $null; probe = [pscustomobject]@{ ok = $false; detail = $_.Exception.GetBaseException().Message } } | ConvertTo-Json -Depth 8; exit 2 }
    $probe = if ($endpoint) { Test-ProxyEndpoint -Endpoint $endpoint } else { [pscustomobject]@{ ok = $false; detail = 'No proxy is enabled.'; elapsedMs = 0 } }
    [pscustomobject]@{ endpoint = $endpoint; probe = $probe; codexRoots = @(Get-CodexRootProcesses); codexUsesProxy = if ($endpoint) { Test-CodexUsesProxy -Endpoint $endpoint } else { $false } } | ConvertTo-Json -Depth 8
    if ($probe.ok) { exit 0 } else { exit 2 }
}

$mutex = New-Object Threading.Mutex($false, (Get-MutexName))
$hasMutex = $false
try {
    try { $hasMutex = $mutex.WaitOne(0, $false) } catch [Threading.AbandonedMutexException] { $hasMutex = $true }
    if (-not $hasMutex) {
        Write-GuardianLog INFO 'guardian.duplicate' 'Another guardian instance already owns the mutex; exiting.'
        exit 0
    }
    if (Test-Path -LiteralPath $script:StopRequestPath) { Remove-Item -LiteralPath $script:StopRequestPath -Force -ErrorAction SilentlyContinue }
    $state = Read-State
    $state.pid = $PID
    $state.startedAt = [DateTimeOffset]::Now.ToString('o')
    $state.productVersion = $script:ProductVersion
    # Process state never survives a guardian restart or user logon. Reset this
    # edge detector so an already-running Codex is checked and relaunched once.
    $state.codexWasRunning = $false
    $state.codexDetectedAt = $null
    $state.lastError = $null
    Save-State $state
    Write-GuardianLog INFO 'guardian.start' 'Codex Proxy Guardian started.' @{ pid = $PID; sourceMode = $script:Config.sourceMode; version = $script:ProductVersion }
    $lastHeartbeat = [DateTimeOffset]::MinValue

    while ($true) {
        if (Test-Path -LiteralPath $script:StopRequestPath) {
            Remove-Item -LiteralPath $script:StopRequestPath -Force -ErrorAction SilentlyContinue
            break
        }
        try {
            [void](Invoke-Observation -State $state)
            $state.lastError = $null
        }
        catch {
            $state.lastError = $_.Exception.GetBaseException().Message
            $state.lastAction = 'loop-error'
            Write-GuardianLog ERROR 'guardian.loop-error' $state.lastError
        }
        $now = [DateTimeOffset]::Now
        if (($now - $lastHeartbeat).TotalSeconds -ge [int](Get-PropertyValue $script:Config 'heartbeatSeconds' 21600)) {
            $state.lastHeartbeatAt = $now.ToString('o')
            Write-GuardianLog INFO 'guardian.heartbeat' 'Guardian heartbeat.' @{ observedProxy = $state.observedProxy; appliedProxy = $state.appliedProxy; probeOk = $state.lastProbeOk; action = $state.lastAction }
            $lastHeartbeat = $now
        }
        Save-State $state
        Start-Sleep -Seconds ([int](Get-PropertyValue $script:Config 'pollSeconds' 5))
    }
    $state.pid = 0
    $state.lastAction = 'stopped'
    Save-State $state
    Write-GuardianLog INFO 'guardian.stop' 'Codex Proxy Guardian stopped normally.'
}
finally {
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
