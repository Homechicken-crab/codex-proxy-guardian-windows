# Shared helpers. Dot-sourcing this file does not change the machine or .env.
Set-StrictMode -Version 2.0
$script:ProxyKeys = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')

function Get-CodexHomePath {
    param([string]$Path)
    if (-not $Path) { $Path = [Environment]::GetEnvironmentVariable('CODEX_HOME', 'Process') }
    if (-not $Path) { $Path = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex' }
    if (-not $Path) { throw 'Cannot locate CODEX_HOME; pass -CodexHome explicitly.' }
    return [IO.Path]::GetFullPath($Path)
}

function ConvertTo-LocalHttpProxy {
    param([string]$Value)
    $uri = $null
    $parsed = [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)
    $local = $false
    if ($parsed) {
        $address = $null
        $local = $uri.Host -eq 'localhost' -or
            ([Net.IPAddress]::TryParse($uri.DnsSafeHost.Trim('[',']'),[ref]$address) -and [Net.IPAddress]::IsLoopback($address))
    }
    if (-not $parsed -or -not $local -or
        $uri.Scheme -ne 'http' -or $uri.Port -lt 1 -or $uri.UserInfo -or
        $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw 'Use a credential-free loopback HTTP or mixed proxy, e.g. http://127.0.0.1:7890. A SOCKS-only port is not an HTTP port.'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Get-WindowsHttpProxy {
    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    $enabled = $settings.PSObject.Properties['ProxyEnable']
    $server = $settings.PSObject.Properties['ProxyServer']
    if (-not $enabled -or $enabled.Value -ne 1 -or -not $server -or -not $server.Value) {
        throw 'No enabled static Windows proxy was found. Start the VPN, or pass -ProxyUrl with its HTTP/mixed port.'
    }
    $raw = [string]$server.Value
    if ($raw.Contains('=')) {
        $map = @{}
        foreach ($part in ($raw -split ';')) {
            if ($part -match '^\s*([^=]+)=(.*?)\s*$') { $map[$matches[1].ToLowerInvariant()] = $matches[2] }
        }
        if ($map.ContainsKey('https')) { $raw = $map['https'] }
        elseif ($map.ContainsKey('http')) { $raw = $map['http'] }
        else { throw 'Windows only specifies a SOCKS proxy. Pass the VPN HTTP/mixed port using -ProxyUrl.' }
    }
    if ($raw -notmatch '^[a-z][a-z0-9+.-]*://') { $raw = 'http://' + $raw }
    return ConvertTo-LocalHttpProxy $raw
}

function Get-ProxyAssignment {
    param([string]$Line)
    if ($Line -cmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
        $key = $matches[1].ToUpperInvariant()
        $value = $matches[2]
        if ($key -in $script:ProxyKeys) { return [pscustomobject]@{ Key=$key; Value=$value } }
    }
    return $null
}

function ConvertTo-EnvLines {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return @() }
    $lines = @($Text -split '\r\n|\n|\r')
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { return @($lines | Select-Object -SkipLast 1) }
    return $lines
}

function Assert-SingleLineDotEnv {
    param([AllowEmptyString()][string]$Text)
    foreach ($line in @(ConvertTo-EnvLines $Text)) {
        if ($line -cnotmatch '^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=(.*)$') { continue }
        $value = $matches[1]
        $quote = 0
        $escaped = $false
        foreach ($character in $value.ToCharArray()) {
            $code = [int]$character
            if ($escaped) { $escaped=$false; continue }
            if ($code -eq 92) { $escaped=$true; continue }
            if ($quote -ne 0) { if ($code -eq $quote) { $quote=0 }; continue }
            if ($code -eq 35) { break }
            if ($code -in @(34,39)) { $quote=$code }
        }
        if ($quote -ne 0 -or $escaped) { throw 'Multiline or continued .env values need manual editing; no configuration was written.' }
    }
}

function Set-ProxyEnvText {
    param([AllowEmptyString()][string]$Text, [System.Collections.IDictionary]$Values)
    Assert-SingleLineDotEnv $Text
    $lines = New-Object 'Collections.Generic.List[string]'
    $seen = @{}
    foreach ($line in @(ConvertTo-EnvLines $Text)) {
        $assignment = Get-ProxyAssignment $line
        if (-not $assignment) { $lines.Add($line); continue }
        if (-not $seen.ContainsKey($assignment.Key)) {
            $lines.Add($assignment.Key + '=' + $Values[$assignment.Key])
            $seen[$assignment.Key] = $true
        }
    }
    foreach ($key in $script:ProxyKeys) {
        if (-not $seen.ContainsKey($key)) { $lines.Add($key + '=' + $Values[$key]) }
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Get-OriginalProxyLines {
    param([AllowEmptyString()][string]$Text)
    $result = [ordered]@{}
    foreach ($key in $script:ProxyKeys) {
        $result[$key] = @(@(ConvertTo-EnvLines $Text) | Where-Object {
            $assignment = Get-ProxyAssignment $_
            $assignment -and $assignment.Key -eq $key
        })
    }
    return $result
}

function Get-NoProxyValue {
    param([AllowEmptyString()][string]$Text)
    $value = ''
    foreach ($line in @(ConvertTo-EnvLines $Text)) {
        $assignment = Get-ProxyAssignment $line
        if ($assignment -and $assignment.Key -eq 'NO_PROXY') { $value = $assignment.Value; break }
    }
    $value = ($value -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
    return ((@($value -split ',' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) + @('localhost','127.0.0.1','::1') | Select-Object -Unique) -join ',')
}

function Assert-PlainFilePath {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to replace a directory or redirected configuration file.'
        }
    }
}

function Write-AtomicText {
    param([string]$Path, [AllowEmptyString()][string]$Text)
    Assert-PlainFilePath $Path
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Read-ProxyState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    Assert-PlainFilePath $Path
    $state = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($state.product -ne 'CodexProxyGuardian' -or $state.schemaVersion -ne 2 -or
        -not $state.PSObject.Properties['originalLines'] -or -not $state.PSObject.Properties['values']) {
        throw 'Unrecognized proxy setup state; refusing to overwrite it.'
    }
    foreach ($key in $script:ProxyKeys) {
        if (-not $state.originalLines.PSObject.Properties[$key] -or -not $state.values.PSObject.Properties[$key]) { throw 'Incomplete proxy setup state.' }
        foreach ($line in @($state.originalLines.$key)) {
            $assignment = Get-ProxyAssignment $line
            if (-not $assignment -or $assignment.Key -ne $key -or $line -match '[\r\n]') { throw 'Invalid saved proxy assignment.' }
        }
    }
    return $state
}

function Restore-ProxyEnvText {
    param([AllowEmptyString()][string]$Text, [object]$State)
    Assert-SingleLineDotEnv $Text
    $lines = @(ConvertTo-EnvLines $Text)
    $restoreKeys = @()
    $conflicts = @()
    foreach ($key in $script:ProxyKeys) {
        $current = @($lines | Where-Object { $a=Get-ProxyAssignment $_; $a -and $a.Key -eq $key })
        if ($current.Count -eq 1 -and [string]::Equals($current[0], ($key + '=' + $State.values.$key), [StringComparison]::Ordinal)) {
            $restoreKeys += $key
        }
        else { $conflicts += $key }
    }
    $output = New-Object 'Collections.Generic.List[string]'
    foreach ($line in $lines) {
        $assignment = Get-ProxyAssignment $line
        if ($assignment -and $assignment.Key -in $restoreKeys) {
            foreach ($original in @($State.originalLines.($assignment.Key))) { $output.Add([string]$original) }
        }
        else { $output.Add($line) }
    }
    $restored = if ($output.Count -gt 0) { ($output -join "`r`n") + "`r`n" } else { '' }
    return [pscustomobject]@{ Text=$restored; Conflicts=@($conflicts) }
}

function Read-HttpHeader {
    param([IO.Stream]$Stream)
    $bytes = New-Object 'Collections.Generic.List[byte]'
    while ($bytes.Count -lt 16384) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { throw 'Unexpected end of HTTP headers.' }
        $bytes.Add([byte]$value)
        if ($bytes.Count -ge 4 -and $bytes[$bytes.Count-4] -eq 13 -and $bytes[$bytes.Count-3] -eq 10 -and $bytes[$bytes.Count-2] -eq 13 -and $bytes[$bytes.Count-1] -eq 10) {
            return [Text.Encoding]::ASCII.GetString($bytes.ToArray())
        }
    }
    throw 'HTTP header limit exceeded.'
}

function Test-HttpProxyRoute {
    param([string]$ProxyUrl, [ValidateRange(250,30000)][int]$TimeoutMs=5000)
    $normalized = ConvertTo-LocalHttpProxy $ProxyUrl
    $uri = [Uri]$normalized
    $client = New-Object Net.Sockets.TcpClient
    $ssl = $null
    $stage = 'tcp'
    try {
        $pending = $client.BeginConnect($uri.DnsSafeHost.Trim('[',']'), $uri.Port, $null, $null)
        try {
            if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw 'Proxy TCP timeout.' }
            $client.EndConnect($pending)
        }
        finally { $pending.AsyncWaitHandle.Close() }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs
        $stage = 'http-connect'
        $request = [Text.Encoding]::ASCII.GetBytes("CONNECT chatgpt.com:443 HTTP/1.1`r`nHost: chatgpt.com:443`r`n`r`n")
        $stream.Write($request,0,$request.Length)
        $header = Read-HttpHeader $stream
        if ($header -notmatch '^HTTP/\S+ 200\b') { throw 'HTTP CONNECT was not accepted.' }
        $stage = 'tls'
        $ssl = New-Object Net.Security.SslStream($stream,$false)
        $ssl.ReadTimeout = $TimeoutMs
        $ssl.WriteTimeout = $TimeoutMs
        $ssl.AuthenticateAsClient('chatgpt.com')
        $stage = 'upgrade-response'
        $key = [Convert]::ToBase64String(([Guid]::NewGuid()).ToByteArray())
        $request = [Text.Encoding]::ASCII.GetBytes("GET /backend-api/codex/responses HTTP/1.1`r`nHost: chatgpt.com`r`nConnection: Upgrade`r`nUpgrade: websocket`r`nSec-WebSocket-Version: 13`r`nSec-WebSocket-Key: $key`r`nOrigin: https://chatgpt.com`r`n`r`n")
        $ssl.Write($request,0,$request.Length)
        $header = Read-HttpHeader $ssl
        if ($header -notmatch '^HTTP/\S+ (\d{3})\b') { throw 'No HTTP response to the Upgrade request.' }
        $status = [int]$matches[1]
        return [pscustomobject]@{ Reachable=$true; Stage='http-response'; HttpStatus=$status; AuthenticatedWebSocket=$false; Note='An unauthenticated HTTP response proves transport reachability, not a working signed-in Codex session.' }
    }
    catch { return [pscustomobject]@{ Reachable=$false; Stage=$stage; HttpStatus=$null; AuthenticatedWebSocket=$false; Note='Check the local HTTP/mixed port, VPN, TLS trust and network route.' } }
    finally { if ($ssl) { $ssl.Dispose() }; $client.Dispose() }
}
