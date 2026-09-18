[CmdletBinding()]
param([switch]$TailLog)

$ErrorActionPreference = 'Stop'
$guardian = Join-Path $PSScriptRoot 'Guardian.ps1'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $guardian -Command Status

if ($TailLog) {
    $log = Join-Path $PSScriptRoot 'logs\guardian.jsonl'
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Tail 20 -Encoding UTF8
    }
}
