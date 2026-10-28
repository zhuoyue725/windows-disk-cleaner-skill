param(
  [ValidateSet('L1','L2')]
  [string]$Level = 'L1',
  [string[]]$Drives = @('C:'),
  [int]$MinCandidateMB = 10,
  [string]$PlanPath = '',
  [ValidateSet('All','SAFE_DELETE','SAFE_IF_CLOSED','ADMIN_SAFE')]
  [string]$Only = 'All',
  [switch]$IncludeRunning,
  [switch]$DryRun,
  [switch]$ClearRecycleBin,
  [switch]$Json
)

$ErrorActionPreference = 'Continue'

$Deleted = New-Object System.Collections.Generic.List[object]
$Skipped = New-Object System.Collections.Generic.List[object]

function Get-IsAdmin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeRows {
  foreach ($drive in $Drives) {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction SilentlyContinue
    if ($disk) {
      [pscustomobject]@{
        drive = $disk.DeviceID
        free_gb = [math]::Round($disk.FreeSpace / 1GB, 2)
        used_gb = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)
        free_pct = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
      }
    }
  }
}

function Get-RobocopySummary {
  # robocopy 的统计标签随系统语言变化（Bytes / 字节 / Байты ...），
  # 固定匹配英文标签在非英文 Windows 上会失配，导致体积恒为 0、候选被全部过滤掉。
  # 按位置取汇总块：robocopy 固定输出 目录/文件/字节 三行，第 3 行首数即字节数。
  param([string[]]$Lines)
  $rows = @()
  foreach ($line in $Lines) {
    if ($line -match '^\s*\S+\s*:\s+((?:\d+\s+){5,}\d+)\s*$') {
      $rows += ,$matches[1].Trim()
    }
  }
  return @($rows)
}

function Get-TreeBytes {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path)) { return 0L }
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return 0L }
  if (-not $item.PSIsContainer) { return [int64]$item.Length }

  $out = & "$env:SystemRoot\System32\robocopy.exe" $Path $env:TEMP /L /S /BYTES /XJ /R:0 /W:0 /NFL /NDL /NJH /NP 2>$null
  $rows = Get-RobocopySummary -Lines @($out)
  if ($rows.Count -ge 3) {
    $parts = ($rows[2] -split '\s+')
    if ($parts.Count -ge 1) { return [int64]$parts[0] }
  }
  foreach ($line in @($out)) {
    if ($line -match '^\s*(?:Bytes|\u5b57\u8282)\s*:\s+([0-9]+)') { return [int64]$matches[1] }
  }
  return 0L
}

function Get-NormalPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Add-Skipped {
  param(
    [string]$Reason,
    [string]$Path,
    [double]$SizeMB = 0,
    [string]$Message = ''
  )
  $Skipped.Add([pscustomobject]@{
    reason = $Reason
    path = $Path
    size_mb = [math]::Round($SizeMB, 2)
    message = $Message
  }) | Out-Null
}

function Get-RunningProcessNames {
  $set = @{}
  Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    $set[$_.ProcessName.ToLowerInvariant()] = $true
  }
  return $set
}

function Get-AllowedRoots {
  $roots = New-Object System.Collections.Generic.List[string]
  # 只允许明确的临时/缓存目录作为删除根。
  # 原实现把整个 LOCALAPPDATA / APPDATA 当作允许根，等价于授权删除
  # 任意用户配置目录（含聊天数据库、应用账号状态），越权风险过高。
  foreach ($path in @(
    (Join-Path $env:LOCALAPPDATA 'Temp'),
    (Join-Path $env:LOCALAPPDATA 'npm-cache'),
    (Join-Path $env:LOCALAPPDATA 'pip\cache'),
    (Join-Path $env:USERPROFILE '.cache\pip'),
    (Join-Path $env:USERPROFILE '.cache\puppeteer'),
    (Join-Path $env:USERPROFILE '.cache\ms-playwright'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\WER'),
    (Join-Path $env:SystemRoot 'Temp'),
    (Join-Path $env:SystemRoot 'Minidump'),
    (Join-Path $env:SystemRoot 'LiveKernelReports')
  )) {
    if ($path -and (Test-Path -LiteralPath $path)) {
      $roots.Add((Get-NormalPath $path)) | Out-Null
    }
  }

  # 浏览器 / 应用缓存目录：按已知模式逐个展开为具体路径，
  # 而不是把整个 LOCALAPPDATA / APPDATA 设为允许根。
  $cachePatterns = @(
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\*\Cache'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\*\Code Cache'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\*\GPUCache'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\*\ShaderCache'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\*\DawnWebGPUCache'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\*\GrShaderCache'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\*\Service Worker\CacheStorage'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\*\Cache'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\*\Code Cache'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\*\GPUCache'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\*\ShaderCache'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\*\DawnWebGPUCache'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\*\Service Worker\CacheStorage'),
    (Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles\*\cache2'),
    (Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles\*\startupCache'),
    (Join-Path $env:LOCALAPPDATA 'Doubao\User Data\Default\Code Cache'),
    (Join-Path $env:APPDATA 'thunder\Cache'),
    (Join-Path $env:APPDATA 'ep_pc_student\logs'),
    (Join-Path $env:APPDATA 'WXDrive\logs'),
    (Join-Path $env:LOCALAPPDATA 'Netease\MailMaster\web\cache'),
    (Join-Path $env:LOCALAPPDATA 'DingTalk_133\Default\Cache'),
    (Join-Path $env:APPDATA 'kingsoft\office6\cache'),
    (Join-Path $env:APPDATA 'Sangfor\aTrust\logs')
  )
  foreach ($pattern in $cachePatterns) {
    foreach ($hit in @(Get-Item -Path $pattern -ErrorAction SilentlyContinue)) {
      $roots.Add((Get-NormalPath $hit.FullName)) | Out-Null
    }
  }

  foreach ($drive in $Drives) {
    foreach ($name in @('DeliveryOptimization','WUDownloadCache')) {
      $root = "$drive\$name"
      if (Test-Path -LiteralPath $root) { $roots.Add((Get-NormalPath $root)) | Out-Null }
    }
  }

  @($roots | Select-Object -Unique)
}

$AllowedRoots = @(Get-AllowedRoots)
$RunningProcesses = Get-RunningProcessNames
$IsAdmin = Get-IsAdmin
$ProtectedPaths = @()
if (-not [string]::IsNullOrWhiteSpace($PlanPath)) {
  $ProtectedPaths += (Get-NormalPath $PlanPath)
}

function Test-UnderAllowedRoot {
  param([string]$Path)
  $full = Get-NormalPath $Path
  foreach ($root in $AllowedRoots) {
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

function Test-NeverDelete {
  param([string]$Path)
  $p = Get-NormalPath $Path
  $fragments = @(
    '\Windows\WinSxS\',
    '\Windows\Installer\',
    '\Program Files\',
    '\Program Files (x86)\',
    '\Windows\System32\',
    '\DriverStore\',
    '\.codex\sessions',
    '\.codex\sqlite',
    '\.cache\codex-runtimes',
    '\AppData\Local\Packages\',
    '\WeChat Files\',
    '\WXWork\Msg\',
    '\MobileSync\Backup\'
  )
  foreach ($fragment in $fragments) {
    if ($p.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
  }
  return $false
}

function Remove-SafePath {
  param(
    [string]$Path,
    [string]$Reason,
    [switch]$ContentsOnly
  )

  if (!(Test-Path -LiteralPath $Path)) { return }
  $full = Get-NormalPath $Path

  if (Test-NeverDelete $full) {
    Add-Skipped -Reason $Reason -Path $full -Message 'protected path'
    return
  }
  foreach ($protected in $ProtectedPaths) {
    if ($protected -and $full.Equals($protected, [StringComparison]::OrdinalIgnoreCase)) {
      Add-Skipped -Reason $Reason -Path $full -Message 'current cleanup plan'
      return
    }
  }
  if (!(Test-UnderAllowedRoot $full)) {
    Add-Skipped -Reason $Reason -Path $full -Message 'outside allowed cleanup roots'
    return
  }

  if ($ContentsOnly) {
    Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | ForEach-Object {
      Remove-SafePath -Path $_.FullName -Reason $Reason
    }
    return
  }

  $bytes = Get-TreeBytes -Path $full
  if ($bytes -lt 1) { return }

  if ($DryRun) {
    $Deleted.Add([pscustomobject]@{
      action = 'would_delete'
      reason = $Reason
      path = $full
      size_mb = [math]::Round($bytes / 1MB, 2)
    }) | Out-Null
    return
  }

  try {
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    $Deleted.Add([pscustomobject]@{
      action = 'deleted'
      reason = $Reason
      path = $full
      size_mb = [math]::Round($bytes / 1MB, 2)
    }) | Out-Null
  } catch {
    Add-Skipped -Reason $Reason -Path $full -SizeMB ([math]::Round($bytes / 1MB, 2)) -Message $_.Exception.Message
  }
}

function Test-CandidateRunning {
  param([object]$Candidate)
  $matched = @()
  foreach ($name in @($Candidate.process_names)) {
    if ($null -eq $name) { continue }
    $key = ([string]$name).ToLowerInvariant()
    if ($RunningProcesses.ContainsKey($key)) { $matched += $key }
  }
  return @($matched | Select-Object -Unique)
}

function Invoke-PlanCleanup {
  param([string]$Path)

  if (!(Test-Path -LiteralPath $Path)) {
    throw "Plan file not found: $Path"
  }

  $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if ($plan.target_drives) {
    $script:Drives = @($plan.target_drives)
  }

  foreach ($candidate in @($plan.candidates)) {
    if ($Only -ne 'All' -and $candidate.risk -ne $Only) {
      continue
    }

    if ($candidate.risk -eq 'ADMIN_SAFE' -and -not $IsAdmin) {
      Add-Skipped -Reason $candidate.category -Path $candidate.path -SizeMB $candidate.size_mb -Message 'administrator permission required'
      continue
    }

    if ($candidate.risk -eq 'SAFE_IF_CLOSED' -and -not $IncludeRunning) {
      $matched = @(Test-CandidateRunning -Candidate $candidate)
      if ($matched.Count -gt 0) {
        Add-Skipped -Reason $candidate.category -Path $candidate.path -SizeMB $candidate.size_mb -Message ("close first: {0}" -f ($matched -join ', '))
        continue
      }
    }

    $contentsOnly = ([string]$candidate.cleanup_action -eq 'contents')
    Remove-SafePath -Path $candidate.path -Reason $candidate.category -ContentsOnly:$contentsOnly
  }
}

function New-FallbackCandidate {
  param(
    [string]$Path,
    [string]$Category,
    [string]$Risk,
    [string]$Action,
    [string[]]$ProcessNames = @()
  )
  if (!(Test-Path -LiteralPath $Path)) { return $null }
  $bytes = Get-TreeBytes -Path $Path
  if ($bytes -lt ($MinCandidateMB * 1MB)) { return $null }
  [pscustomobject]@{
    path = Get-NormalPath $Path
    category = $Category
    risk = $Risk
    cleanup_action = $Action
    size_mb = [math]::Round($bytes / 1MB, 2)
    process_names = @($ProcessNames)
  }
}

function Get-FallbackCandidates {
  $rows = New-Object System.Collections.Generic.List[object]

  foreach ($item in @(
    @{ Path = (Join-Path $env:LOCALAPPDATA 'Temp'); Category = 'user temp'; Risk = 'SAFE_DELETE'; Action = 'contents'; Processes = @() },
    @{ Path = (Join-Path $env:SystemRoot 'Temp'); Category = 'windows temp'; Risk = 'ADMIN_SAFE'; Action = 'contents'; Processes = @() },
    @{ Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER'); Category = 'error reports'; Risk = 'ADMIN_SAFE'; Action = 'contents'; Processes = @() },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Profile 1\Cache'); Category = 'browser cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('chrome') },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Profile 1\Code Cache'); Category = 'browser cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('chrome') },
    @{ Path = (Join-Path $env:APPDATA 'kingsoft\office6\cache'); Category = 'app cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('wps','wpp','et','wpscloudsvr','wpsdoccenter') },
    @{ Path = (Join-Path $env:APPDATA 'Sangfor\aTrust\logs'); Category = 'security app logs'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('atrust','atrustxtunnel','atrusttray','atrustagent') }
  )) {
    $row = New-FallbackCandidate -Path $item.Path -Category $item.Category -Risk $item.Risk -Action $item.Action -ProcessNames $item.Processes
    if ($row) { $rows.Add($row) | Out-Null }
  }

  return @($rows)
}

function Invoke-FallbackCleanup {
  foreach ($candidate in @(Get-FallbackCandidates)) {
    if ($Only -ne 'All' -and $candidate.risk -ne $Only) { continue }
    if ($candidate.risk -eq 'ADMIN_SAFE' -and -not $IsAdmin) {
      Add-Skipped -Reason $candidate.category -Path $candidate.path -SizeMB $candidate.size_mb -Message 'administrator permission required'
      continue
    }
    if ($candidate.risk -eq 'SAFE_IF_CLOSED' -and -not $IncludeRunning) {
      $matched = @(Test-CandidateRunning -Candidate $candidate)
      if ($matched.Count -gt 0) {
        Add-Skipped -Reason $candidate.category -Path $candidate.path -SizeMB $candidate.size_mb -Message ("close first: {0}" -f ($matched -join ', '))
        continue
      }
    }
    Remove-SafePath -Path $candidate.path -Reason $candidate.category -ContentsOnly:([string]$candidate.cleanup_action -eq 'contents')
  }
}

$before = @(Get-FreeRows)

if ([string]::IsNullOrWhiteSpace($PlanPath)) {
  Invoke-FallbackCleanup
} else {
  Invoke-PlanCleanup -Path $PlanPath
}

if (-not $DryRun) {
  # 只在显式要求时清空回收站。原实现无条件清空，会连带销毁用户自己
  # 刚放进回收站、尚未确认删除的文件，属于不可逆越权操作。
  if ($ClearRecycleBin) {
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}
  }
}

$after = @(Get-FreeRows)

$deletedMb = ($Deleted | Measure-Object size_mb -Sum).Sum
if ($null -eq $deletedMb) { $deletedMb = 0 }
$skippedMb = ($Skipped | Measure-Object size_mb -Sum).Sum
if ($null -eq $skippedMb) { $skippedMb = 0 }

$result = [pscustomobject]@{
  generated_at = (Get-Date).ToString('s')
  level = $Level
  dry_run = [bool]$DryRun
  plan_path = $PlanPath
  only = $Only
  include_running = [bool]$IncludeRunning
  before = @($before)
  after = @($after)
  estimated_deleted_mb = [math]::Round($deletedMb, 2)
  estimated_skipped_mb = [math]::Round($skippedMb, 2)
  deleted_count = $Deleted.Count
  skipped_count = $Skipped.Count
  deleted = @($Deleted.ToArray())
  skipped = @($Skipped.ToArray() | Sort-Object size_mb -Descending | Select-Object -First 100)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  'Before'
  $before | Format-Table -AutoSize
  ''
  'After'
  $after | Format-Table -AutoSize
  ''
  'Summary'
  $result | Select-Object level,dry_run,only,estimated_deleted_mb,estimated_skipped_mb,deleted_count,skipped_count | Format-List
  ''
  'Deleted groups'
  $Deleted | Group-Object reason | ForEach-Object {
    $mb = ($_.Group | Measure-Object size_mb -Sum).Sum
    [pscustomobject]@{ reason = $_.Name; items = $_.Count; size_mb = [math]::Round($mb, 2) }
  } | Sort-Object size_mb -Descending | Format-Table -AutoSize
  ''
  'Skipped groups'
  $Skipped | Group-Object message | ForEach-Object {
    $mb = ($_.Group | Measure-Object size_mb -Sum).Sum
    [pscustomobject]@{ message = $_.Name; items = $_.Count; size_mb = [math]::Round($mb, 2) }
  } | Sort-Object size_mb -Descending | Format-Table -AutoSize
}
