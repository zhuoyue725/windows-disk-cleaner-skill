param(
  [string]$TaskName = 'Windows Disk Cleaner Skill',

  [ValidateSet('Daily','Weekly')]
  [string]$Frequency = 'Daily',

  [Alias('At')]
  [string]$RunAt = '09:00',

  [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
  [string]$DayOfWeek = 'Sunday',

  [ValidateSet('L1','L2')]
  [string]$Level = 'L1',

  [string[]]$Drives = @('C:', 'D:'),
  [int]$MinCandidateMB = 50,
  [string]$PrimaryDrive = 'C:',
  [int]$EscalateToL2BelowGB = 0,
  [switch]$Remove,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

function New-Result {
  param([string]$Status, [string]$Message, [hashtable]$Data = @{})
  $base = [ordered]@{
    generated_at = (Get-Date).ToString('s')
    status = $Status
    message = $Message
  }
  foreach ($key in $Data.Keys) { $base[$key] = $Data[$key] }
  [pscustomobject]$base
}

function Write-Result {
  param([object]$Result)
  if ($Json) {
    $Result | ConvertTo-Json -Depth 6
  } else {
    $Result | Format-List
  }
}

if ($Remove) {
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Result (New-Result -Status 'removed' -Message 'Scheduled cleanup task removed.' @{ task_name = $TaskName })
  } else {
    Write-Result (New-Result -Status 'not_found' -Message 'Scheduled cleanup task was not found.' @{ task_name = $TaskName })
  }
  exit 0
}

try {
  $time = [datetime]::ParseExact($RunAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
} catch {
  throw 'RunAt must use HH:mm format, for example 09:00 or 21:30.'
}

$cleanScript = Join-Path $PSScriptRoot 'clean_space.ps1'
if (!(Test-Path -LiteralPath $cleanScript)) {
  throw "clean_space.ps1 not found next to schedule_cleanup.ps1."
}

$stateDir = Join-Path $env:LOCALAPPDATA 'WindowsDiskCleanerSkill'
$logDir = Join-Path $stateDir 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$runner = Join-Path $stateDir 'run_scheduled_cleanup.ps1'
$logFile = Join-Path $logDir 'scheduled-cleanup.jsonl'
$driveLiteral = ($Drives | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
$cleanEscaped = $cleanScript -replace "'", "''"
$logEscaped = $logFile -replace "'", "''"

$runnerContent = @"
`$ErrorActionPreference = 'Continue'
`$level = '$Level'
`$threshold = $EscalateToL2BelowGB
`$primaryDrive = '$PrimaryDrive'
if (`$threshold -gt 0) {
  `$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='`$primaryDrive'" -ErrorAction SilentlyContinue
  if (`$disk -and (`$disk.FreeSpace / 1GB) -lt `$threshold) {
    `$level = 'L2'
  }
}
`$record = & '$cleanEscaped' -Level `$level -Drives $driveLiteral -MinCandidateMB $MinCandidateMB -Json
`$record | Out-File -FilePath '$logEscaped' -Encoding UTF8 -Append
"@

Set-Content -LiteralPath $runner -Value $runnerContent -Encoding UTF8

$trigger = if ($Frequency -eq 'Daily') {
  New-ScheduledTaskTrigger -Daily -At $time
} else {
  New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $time
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $runner)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$description = 'Runs low-risk Windows disk cleanup from the windows-disk-cleaner agent skill.'

Register-ScheduledTask -TaskName $TaskName -Trigger $trigger -Action $action -Settings $settings -Description $description -Force | Out-Null

Write-Result (New-Result -Status 'scheduled' -Message 'Scheduled cleanup task created.' @{
  task_name = $TaskName
  frequency = $Frequency
  run_at = $RunAt
  day_of_week = if ($Frequency -eq 'Weekly') { $DayOfWeek } else { $null }
  default_level = $Level
  escalate_to_l2_below_gb = $EscalateToL2BelowGB
  drives = $Drives
  runner = $runner
  log_file = $logFile
})
