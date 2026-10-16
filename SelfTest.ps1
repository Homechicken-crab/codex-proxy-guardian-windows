[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProxyConfig.ps1')
$script:Passed = 0
function Assert-Check { param([bool]$Condition,[string]$Name); if (-not $Condition) { throw ('FAIL: '+$Name) }; $script:Passed++; Write-Output ('PASS: '+$Name) }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-test-' + [Guid]::NewGuid().ToString('N'))
$install = Join-Path $PSScriptRoot 'Install.ps1'
$uninstall = Join-Path $PSScriptRoot 'Uninstall.ps1'
$diagnose = Join-Path $PSScriptRoot 'Diagnose.ps1'
try {
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        Assert-Check ($errors.Count -eq 0) ('PowerShell parses: '+$file.Name)
    }
    foreach ($url in @('socks5://127.0.0.1:7890','http://example.invalid:7890','http://name:pass@127.0.0.1:7890','http://127.0.0.1:7890/path','http://127.0.0.1:7890?x=1','https://127.0.0.1:7890','http://127.0.0.1:0')) {
        $rejected=$false
        try { [void](ConvertTo-LocalHttpProxy $url) } catch { $rejected=$true }
        Assert-Check $rejected 'Reject unsupported, remote, authenticated or malformed proxy URL'
    }
    $ipv6Proxy = [Uri](ConvertTo-LocalHttpProxy 'http://[::1]:7890')
    Assert-Check ($ipv6Proxy.Port -eq 7890 -and [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($ipv6Proxy.DnsSafeHost.Trim('[',']')))) 'IPv6 loopback proxy accepted'
    $noWrite = Join-Path $testRoot 'what-if'
    & $install -CodexHome $noWrite -ProxyUrl 'http://127.0.0.1:7890' -SkipProbe -SkipLegacyCleanup -WhatIf | Out-Null
    Assert-Check (-not (Test-Path -LiteralPath $noWrite)) 'WhatIf creates no files or directories'
    $existing = Join-Path $testRoot 'existing'
    New-Item -ItemType Directory -Path $existing -Force | Out-Null
    $envPath = Join-Path $existing '.env'
    $original = "# keep this comment`r`nUNRELATED_TEST_VALUE=example-only`r`nexport http_proxy=http://127.0.0.1:8080`r`nHTTP_PROXY=http://127.0.0.1:8081`r`nNO_PROXY=example.invalid`r`n"
    [IO.File]::WriteAllText($envPath,$original)
    & $install -CodexHome $existing -ProxyUrl 'http://127.0.0.1:7890' -SkipProbe -SkipLegacyCleanup | Out-Null
    $first = [IO.File]::ReadAllText($envPath)
    Assert-Check ($first.Contains('# keep this comment') -and $first.Contains('UNRELATED_TEST_VALUE=example-only')) 'Existing unrelated data preserved'
    Assert-Check (@(ConvertTo-EnvLines $first | Where-Object { $a=Get-ProxyAssignment $_; $a -and $a.Key -eq 'HTTP_PROXY' }).Count -eq 1) 'Case variants and duplicate proxy assignments consolidated'
    Assert-Check ($first.Contains('NO_PROXY=example.invalid,localhost,127.0.0.1,::1')) 'Existing exclusions retained with loopback bypass'
    & $install -CodexHome $existing -ProxyUrl 'http://127.0.0.1:7890' -SkipProbe -SkipLegacyCleanup | Out-Null
    Assert-Check ([IO.File]::ReadAllText($envPath) -ceq $first) 'Reinstall is idempotent'
    & $install -CodexHome $existing -ProxyUrl 'http://127.0.0.1:7891' -SkipProbe -SkipLegacyCleanup | Out-Null
    & $uninstall -CodexHome $existing -Confirm:$false | Out-Null
    Assert-Check ([IO.File]::ReadAllText($envPath) -ceq $original) 'Updating endpoint still restores the original assignments'
    & $install -CodexHome $existing -ProxyUrl 'http://127.0.0.1:7890' -SkipProbe -SkipLegacyCleanup | Out-Null
    $changed = [IO.File]::ReadAllText($envPath).Replace('HTTPS_PROXY=http://127.0.0.1:7890','HTTPS_PROXY=http://127.0.0.1:9000') + "NEW_TEST_VALUE=keep`r`n"
    [IO.File]::WriteAllText($envPath,$changed)
    $removal = (& $uninstall -CodexHome $existing -Confirm:$false | Out-String) | ConvertFrom-Json
    $after = [IO.File]::ReadAllText($envPath)
    Assert-Check ($after.Contains('HTTPS_PROXY=http://127.0.0.1:9000') -and $removal.preservedUserModifiedKeys -contains 'HTTPS_PROXY') 'Uninstall preserves user-modified proxy values'
    Assert-Check ($after.Contains('NEW_TEST_VALUE=keep')) 'Uninstall preserves later unrelated additions'
    $fresh = Join-Path $testRoot 'fresh'
    & $install -CodexHome $fresh -ProxyUrl 'http://127.0.0.1:7890' -SkipProbe -SkipLegacyCleanup | Out-Null
    $redacted = & $diagnose -CodexHome $fresh | Out-String
    Assert-Check (-not $redacted.Contains($fresh) -and -not $redacted.Contains('7890') -and -not $redacted.Contains('UNRELATED_TEST_VALUE')) 'Diagnostic output omits paths, endpoints and environment values'
    & $uninstall -CodexHome $fresh -Confirm:$false | Out-Null
    Assert-Check (-not [IO.File]::Exists((Join-Path $fresh '.env'))) 'New empty configuration is removed on uninstall'
    & $uninstall -CodexHome $fresh -Confirm:$false | Out-Null
    Assert-Check (-not [IO.File]::Exists((Join-Path $fresh 'proxy-setup-state.json'))) 'Uninstall without state is a safe no-op'
    $unknown = Join-Path $testRoot 'unknown'
    New-Item -ItemType Directory -Path $unknown | Out-Null
    [IO.File]::WriteAllText((Join-Path $unknown 'proxy-setup-state.json'),'{"product":"different"}')
    $rejected=$false
    try { & $install -CodexHome $unknown -ProxyUrl 'http://127.0.0.1:7890' -SkipProbe -SkipLegacyCleanup | Out-Null } catch { $rejected=$true }
    Assert-Check ($rejected -and -not [IO.File]::Exists((Join-Path $unknown '.env'))) 'Unknown state rejected before changing .env'
    $multiline = Join-Path $testRoot 'multiline'
    New-Item -ItemType Directory -Path $multiline | Out-Null
    $multilinePath = Join-Path $multiline '.env'
    $multilineText = "UNRELATED_TEST_VALUE=`"first line`r`nHTTP_PROXY=inside-quoted-value`r`nlast line`"`r`n"
    [IO.File]::WriteAllText($multilinePath,$multilineText)
    $rejected=$false
    try { & $install -CodexHome $multiline -ProxyUrl 'http://127.0.0.1:7890' -SkipProbe -SkipLegacyCleanup | Out-Null } catch { $rejected=$true }
    Assert-Check ($rejected -and [IO.File]::ReadAllText($multilinePath) -ceq $multilineText -and -not [IO.File]::Exists((Join-Path $multiline 'proxy-setup-state.json'))) 'Multiline values rejected without altering unrelated content'
    $commentAccepted=$true
    try { Assert-SingleLineDotEnv "UNRELATED_TEST_VALUE=plain # comment's quote`r`n" } catch { $commentAccepted=$false }
    Assert-Check $commentAccepted 'Quotes inside comments do not trigger multiline rejection'
    $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection established`r`nX-Test: yes`r`n`r`nTLS-DATA")
    $stream = New-Object IO.MemoryStream(,$bytes)
    try { $header=Read-HttpHeader $stream; Assert-Check ($header.EndsWith("`r`n`r`n") -and $stream.Position -eq ($bytes.Length-8)) 'CONNECT parser does not consume tunneled TLS bytes' } finally { $stream.Dispose() }
    $stream = New-Object IO.MemoryStream(,[byte[]]@(5,0))
    $rejected=$false
    try { [void](Read-HttpHeader $stream) } catch { $rejected=$true } finally { $stream.Dispose() }
    Assert-Check $rejected 'SOCKS or incomplete HTTP headers cannot pass the HTTP parser'
    Write-Output ('All '+$script:Passed+' checks passed. Only temporary fixtures were modified; no real .env, tasks, proxy or dial-up configuration was changed.')
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^codex-proxy-test-[a-f0-9]{32}$') { throw 'Unexpected test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
