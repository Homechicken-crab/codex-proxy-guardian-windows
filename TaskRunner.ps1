Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$guardian = Join-Path $PSScriptRoot 'Guardian.ps1'
$logDirectory = Join-Path $PSScriptRoot 'logs'
$errorLog = Join-Path $logDirectory 'startup-errors.log'
$utf8 = New-Object Text.UTF8Encoding($false)

try {
    & $guardian -Command Run
}
catch {
    try {
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        $exception = $_.Exception.GetBaseException()
        $line = '{0} | {1} | {2}{3}' -f [DateTimeOffset]::Now.ToString('o'), $exception.Message, $_.ScriptStackTrace, [Environment]::NewLine
        [IO.File]::AppendAllText($errorLog, $line, $utf8)
    }
    catch { }
    exit 1
}
