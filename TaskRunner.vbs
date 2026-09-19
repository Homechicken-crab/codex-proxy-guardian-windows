Option Explicit

Dim shell, fileSystem, scriptDirectory, powershellPath, runnerPath, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
runnerPath = fileSystem.BuildPath(scriptDirectory, "TaskRunner.ps1")
command = Chr(34) & powershellPath & Chr(34) & _
    " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & runnerPath & Chr(34)

' Window style 0 keeps both Windows PowerShell and its console host invisible.
' A nonzero exit is retried after one minute. A normal stop exits the wrapper.
Do
    exitCode = shell.Run(command, 0, True)
    If exitCode = 0 Then Exit Do
    WScript.Sleep 60000
Loop

WScript.Quit 0
