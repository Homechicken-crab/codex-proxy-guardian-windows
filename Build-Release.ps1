[CmdletBinding()]
param(
    [string]$Version = '1.1.0',
    [switch]$LiveTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Version must use semantic version format, for example 1.1.0.'
}

$selfTest = Join-Path $PSScriptRoot 'SelfTest.ps1'
$testArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $selfTest)
if ($LiveTest) { $testArgs += '-Live' }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @testArgs
if ($LASTEXITCODE -ne 0) { throw 'Self-test failed; release was not built.' }

$releaseFiles = @(
    'Guardian.ps1',
    'TaskRunner.ps1',
    'Install.ps1',
    'Status.ps1',
    'Diagnose.ps1',
    'Uninstall.ps1',
    'SelfTest.ps1',
    'Build-Release.ps1',
    'README.md',
    'CHANGELOG.md',
    'VALIDATION.md',
    'config.json'
)

$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$archive = Join-Path $dist "CodexProxyGuardian-v$Version.zip"
$checksum = "$archive.sha256"
$staging = Join-Path ([IO.Path]::GetTempPath()) ("CodexProxyGuardian-release-" + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $staging 'CodexProxyGuardian'

try {
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    foreach ($name in $releaseFiles) {
        $source = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release file is missing: $name" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $payload $name)
    }
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -LiteralPath $payload -DestinationPath $archive -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksum, "$hash  $([IO.Path]::GetFileName($archive))`r`n", (New-Object Text.UTF8Encoding($false)))
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}

[pscustomobject][ordered]@{
    version = $Version
    archive = $archive
    sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    liveTest = [bool]$LiveTest
} | ConvertTo-Json -Depth 4
