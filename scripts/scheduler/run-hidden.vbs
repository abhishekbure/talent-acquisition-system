' TAMS - runs a program without a console window and returns its exit code (Phase 12).
' Task Scheduler starts:  wscript.exe //B //Nologo run-hidden.vbs "<program>" <arguments...>
' so a task that runs every 5 minutes does not flash a window, and Task Scheduler still sees the program's exit code
' ("Last Run Result"). Every argument is passed on quoted.
Option Explicit
Dim sh, cmd, i, rc
If WScript.Arguments.Count = 0 Then WScript.Quit 64
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & """" & Replace(WScript.Arguments(i), """", "") & """ "
Next
Set sh = CreateObject("WScript.Shell")
rc = sh.Run(Trim(cmd), 0, True)   ' 0 = hidden window, True = wait for it to finish
WScript.Quit rc
