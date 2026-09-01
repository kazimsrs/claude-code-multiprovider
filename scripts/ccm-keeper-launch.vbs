' Launches ccm-keeper.ps1 completely hidden (window style 0), so the every-minute scheduled task
' never flashes a console window. Location-independent: finds the .ps1 next to this script.
Dim fso, shell, here, ps1
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "ccm-keeper.ps1")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
