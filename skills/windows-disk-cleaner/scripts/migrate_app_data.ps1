param(
  [Parameter(Mandatory = $true)]
  [string]$Source,

  [Parameter(Mandatory = $true)]
  [string]$DestinationRoot,

  [string]$Name,
  [string[]]$ProcessName = @(),
  [string]$BackupPath,
  [switch]$AllowProgramData,
  [switch]$ContinueIfRunning,
  [switch]$Rollback,
  [switch]$DryRun,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

function New-Result {
  param(
    [string]$Status,
    [string]$Message,
    [hashtable]$Data = @{}
  )

  $base = [ordered]@{
    generated_at = (Get-Date).ToString('s')
    status = $Status
    message = $Message
  }

  foreach ($key in $Data.Keys) {
    $base[$key] = $Data[$key]
  }

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

function Stop-WithResult {
  param([string]$Message, [hashtable]$Data = @{})
  $result = New-Result -Status 'blocked' -Message $Message -Data $Data
  Write-Result $result
  exit 2
}

function Get-FullPath {
  param([string]$Path)
  [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathUnder {
  param([string]$Path, [string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
  $full = Get-FullPath $Path
  $rootFull = Get-FullPath $Root
  return $full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
    $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-TreeStats {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{ files = 0; bytes = 0L }
  }

  # robocopy 统计行标签随系统语言变化（Files/Bytes vs 文件/字节），
  # 固定匹配英文标签会让 bytes 恒为 0，进而使下方的体积校验形同虚设。
  # 改为按位置取汇总块第 2 行（文件数）和第 3 行（字节数）。
  $out = & "$env:SystemRoot\System32\robocopy.exe" $Path $env:TEMP /L /S /BYTES /XJ /R:0 /W:0 /NFL /NDL /NJH /NP 2>$null
  $rows = @()
  foreach ($line in @($out)) {
    if ($line -match '^\s*\S+\s*:\s+((?:\d+\s+){5,}\d+)\s*$') {
      $rows += ,$matches[1].Trim()
    }
  }

  $files = 0
  $bytes = 0L
  if ($rows.Count -ge 2) {
    $p = ($rows[1] -split '\s+')
    if ($p.Count -ge 1) { $files = [int]$p[0] }
  }
  if ($rows.Count -ge 3) {
    $p = ($rows[2] -split '\s+')
    if ($p.Count -ge 1) { $bytes = [int64]$p[0] }
  }

  # 回退：兼容英文/中文标签
  if ($bytes -eq 0) {
    foreach ($line in @($out)) {
      if ($line -match '^\s*(?:Files|\u6587\u4ef6)\s*:\s+([0-9]+)') { $files = [int]$matches[1] }
      if ($line -match '^\s*(?:Bytes|\u5b57\u8282)\s*:\s+([0-9]+)') { $bytes = [int64]$matches[1] }
    }
  }

  [pscustomobject]@{ files = $files; bytes = $bytes }
}

function Get-BlockedProcesses {
  $running = New-Object System.Collections.Generic.List[string]
  foreach ($name in $ProcessName) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $plain = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $hit = Get-Process -Name $plain -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $running.Add($plain) | Out-Null }
  }
  @($running | Sort-Object -Unique)
}

function Assert-SafeSource {
  param([string]$Path)

  $sourceFull = Get-FullPath $Path
  $root = [System.IO.Path]::GetPathRoot($sourceFull).TrimEnd('\')
  if ($sourceFull.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
    Stop-WithResult 'Source cannot be a whole drive root.' @{ source = $sourceFull }
  }

  $blockedExact = @(
    $env:USERPROFILE,
    $env:LOCALAPPDATA,
    $env:APPDATA,
    $env:ProgramData,
    $env:SystemRoot,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)}
  ) | Where-Object { $_ }

  foreach ($blocked in $blockedExact) {
    if ($sourceFull.Equals((Get-FullPath $blocked), [StringComparison]::OrdinalIgnoreCase)) {
      Stop-WithResult 'Source is too broad to migrate safely. Choose a specific app data folder.' @{ source = $sourceFull }
    }
  }

  $neverRoots = @(
    $env:SystemRoot,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    "$env:USERPROFILE\.codex\sessions",
    "$env:USERPROFILE\.codex\sqlite",
    "$env:USERPROFILE\.cache\codex-runtimes"
  ) | Where-Object { $_ }

  foreach ($rootPath in $neverRoots) {
    if (Test-PathUnder $sourceFull $rootPath) {
      Stop-WithResult 'Source is protected and must not be migrated by this helper.' @{ source = $sourceFull; protected_root = $rootPath }
    }
  }

  if ((Test-PathUnder $sourceFull $env:ProgramData) -and -not $AllowProgramData) {
    Stop-WithResult 'ProgramData migration requires -AllowProgramData and an explicit app-specific path.' @{
      source = $sourceFull
      hint = 'Use only for app-owned cache/data folders, not security databases or system stores.'
    }
  }
}

function Invoke-RobocopyMirror {
  param([string]$From, [string]$To)
  & "$env:SystemRoot\System32\robocopy.exe" $From $To /MIR /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NP | Out-Null
  $code = $LASTEXITCODE
  if ($code -ge 8) {
    throw "Robocopy failed with exit code $code."
  }
}

function Invoke-Rollback {
  $sourceFull = Get-FullPath $Source
  if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    Stop-WithResult 'Rollback requires -BackupPath so the correct backup is restored.' @{ source = $sourceFull }
  }

  $backupFull = Get-FullPath $BackupPath
  if (!(Test-Path -LiteralPath $backupFull)) {
    Stop-WithResult 'Backup path was not found.' @{ backup_path = $backupFull }
  }

  if (!(Test-Path -LiteralPath $sourceFull)) {
    Stop-WithResult 'Source junction was not found.' @{ source = $sourceFull }
  }

  $sourceItem = Get-Item -LiteralPath $sourceFull -Force
  if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
    Stop-WithResult 'Source is not a junction/reparse point. Rollback stopped.' @{ source = $sourceFull }
  }

  if ($DryRun) {
    Write-Result (New-Result -Status 'dry_run' -Message 'Rollback plan generated.' -Data @{
      remove_junction = $sourceFull
      restore_backup = $backupFull
    })
    return
  }

  Remove-Item -LiteralPath $sourceFull -Force
  Rename-Item -LiteralPath $backupFull -NewName (Split-Path -Leaf $sourceFull)

  Write-Result (New-Result -Status 'rolled_back' -Message 'Junction removed and backup restored.' -Data @{
    source = $sourceFull
    restored_from = $backupFull
  })
}

if ($Rollback) {
  Invoke-Rollback
  exit 0
}

if (!(Test-Path -LiteralPath $Source)) {
  Stop-WithResult 'Source path was not found.' @{ source = $Source }
}

$sourceFull = Get-FullPath (Resolve-Path -LiteralPath $Source).Path
Assert-SafeSource -Path $sourceFull

$sourceItem = Get-Item -LiteralPath $sourceFull -Force
if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
  Stop-WithResult 'Source is already a junction or reparse point.' @{ source = $sourceFull }
}

$running = Get-BlockedProcesses
if ($running.Count -gt 0 -and -not $ContinueIfRunning) {
  Stop-WithResult 'Close the listed app process before migration.' @{
    source = $sourceFull
    running_processes = $running
  }
}

if ([string]::IsNullOrWhiteSpace($Name)) {
  $Name = Split-Path -Leaf $sourceFull
}

$safeName = ($Name -replace '[<>:"/\\|?*]', '_').Trim()
if ([string]::IsNullOrWhiteSpace($safeName)) {
  Stop-WithResult 'Destination name is empty after sanitizing.' @{ name = $Name }
}

if (!(Test-Path -LiteralPath $DestinationRoot)) {
  if (-not $DryRun) {
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
  }
}

$destinationRootFull = Get-FullPath $DestinationRoot
$destinationFull = Get-FullPath (Join-Path $destinationRootFull $safeName)

if (Test-PathUnder $destinationFull $sourceFull) {
  Stop-WithResult 'Destination cannot be inside the source folder.' @{
    source = $sourceFull
    destination = $destinationFull
  }
}

if (Test-Path -LiteralPath $destinationFull) {
  $existing = @(Get-ChildItem -LiteralPath $destinationFull -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($existing.Count -gt 0) {
    Stop-WithResult 'Destination already exists and is not empty.' @{ destination = $destinationFull }
  }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupFull = Join-Path (Split-Path -Parent $sourceFull) ("{0}.bak-{1}" -f (Split-Path -Leaf $sourceFull), $stamp)
$sourceStats = Get-TreeStats -Path $sourceFull

if ($DryRun) {
  Write-Result (New-Result -Status 'dry_run' -Message 'Migration plan generated. No files changed.' -Data @{
    source = $sourceFull
    destination = $destinationFull
    backup_path = $backupFull
    size_gb = [math]::Round($sourceStats.bytes / 1GB, 2)
    files = $sourceStats.files
    steps = @('copy source to destination', 'rename source to backup', 'create junction at original source path')
  })
  exit 0
}

New-Item -ItemType Directory -Path $destinationFull -Force | Out-Null
Invoke-RobocopyMirror -From $sourceFull -To $destinationFull

$destStats = Get-TreeStats -Path $destinationFull
if ($sourceStats.bytes -gt 0 -and $destStats.bytes -lt [int64]($sourceStats.bytes * 0.98)) {
  Stop-WithResult 'Copied data size is unexpectedly smaller than source. Source was not changed.' @{
    source = $sourceFull
    destination = $destinationFull
    source_gb = [math]::Round($sourceStats.bytes / 1GB, 2)
    destination_gb = [math]::Round($destStats.bytes / 1GB, 2)
  }
}

Rename-Item -LiteralPath $sourceFull -NewName (Split-Path -Leaf $backupFull)

$mklinkCommand = 'mklink /J "{0}" "{1}"' -f $sourceFull, $destinationFull
& "$env:ComSpec" /c $mklinkCommand | Out-Null
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $sourceFull)) {
  Rename-Item -LiteralPath $backupFull -NewName (Split-Path -Leaf $sourceFull)
  Stop-WithResult 'Failed to create junction. Backup was restored.' @{
    source = $sourceFull
    destination = $destinationFull
  }
}

Write-Result (New-Result -Status 'migrated' -Message 'Data copied, original path converted to junction, backup kept for rollback.' -Data @{
  source = $sourceFull
  destination = $destinationFull
  backup_path = $backupFull
  source_size_gb = [math]::Round($sourceStats.bytes / 1GB, 2)
  destination_size_gb = [math]::Round($destStats.bytes / 1GB, 2)
  rollback_command = ".\migrate_app_data.ps1 -Rollback -Source `"$sourceFull`" -BackupPath `"$backupFull`""
})
