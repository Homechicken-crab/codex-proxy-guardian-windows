[CmdletBinding()]
param([string]$Version='2.0.0')
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Use a semantic version number.' }
& (Join-Path $PSScriptRoot 'SelfTest.ps1')
# Fixed allowlist: never package a user's .env, restoration state or diagnostics.
$files=@('Install.ps1','Uninstall.ps1','ProxyConfig.ps1','LegacyMigration.ps1','Diagnose.ps1','SelfTest.ps1','Build-Release.ps1','README.md','CHANGELOG.md','VALIDATION.md','PRIVACY.md')
foreach($file in $files){ if(-not [IO.File]::Exists((Join-Path $PSScriptRoot $file))){throw ('Missing release file: '+$file)} }
$dist=Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$archive=Join-Path $dist ('CodexProxyGuardian-v'+$Version+'.zip')
if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive -Force}
Compress-Archive -LiteralPath @($files | ForEach-Object {Join-Path $PSScriptRoot $_}) -DestinationPath $archive -CompressionLevel Optimal
$hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($archive+'.sha256'),($hash+'  '+[IO.Path]::GetFileName($archive)+"`r`n"),(New-Object Text.UTF8Encoding($false)))
Write-Output ('Built '+[IO.Path]::GetFileName($archive)+' from '+$files.Count+' allowlisted source files.')
