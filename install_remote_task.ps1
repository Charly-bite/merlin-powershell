$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\QB_DESARROLLO\Desktop\Merlin\start_all_services.ps1"'
$trigger = New-ScheduledTaskTrigger -Daily -At "07:30"
Register-ScheduledTask -TaskName "Merlin_AutoStart_0730" -Action $action -Trigger $trigger -Description "Levantamiento automatico de servicios Merlin a las 7:30 AM" -Force
Get-ScheduledTask -TaskName "Merlin_AutoStart_0730" | Select-Object TaskName, State
(Get-ScheduledTask -TaskName "Merlin_AutoStart_0730" | Get-ScheduledTaskInfo) | Select-Object TaskName, NextRunTime
