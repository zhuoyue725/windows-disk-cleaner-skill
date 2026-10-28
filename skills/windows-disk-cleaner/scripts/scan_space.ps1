param(
  [string[]]$Drives = @('C:'),
  [int]$Top = 25,
  [int]$MinCandidateMB = 10,
  [ValidateSet('Fast','Deep')]
  [string]$Mode = 'Fast',
  [string]$PlanPath = '',
  [switch]$Json,
  [switch]$IncludeInstalledApps
)

$ErrorActionPreference = 'Continue'

# 命令行传入 -Drives C:,G: 时会被当成单个字符串 "C:,G:"，统一拆分。
$normalizedDrives = @()
foreach ($d in @($Drives)) {
  foreach ($part in ([string]$d -split ',')) {
    $t = $part.Trim()
    if ($t) { $normalizedDrives += $t }
  }
}
$Drives = @($normalizedDrives)

function Get-RobocopySummary {
  # robocopy 的统计行标签随系统语言变化（Bytes / 字节 / Байты ...），
  # 固定匹配英文标签在非英文 Windows 上会全部失配导致体积恒为 0。
  # 这里按位置取：robocopy 汇总块固定为 目录/文件/字节 三行，取第 3 行的首个数字即字节数。
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
  # 回退：兼容标签匹配（英文/中文）
  foreach ($line in @($out)) {
    if ($line -match '^\s*(?:Bytes|\u5b57\u8282)\s*:\s+([0-9]+)') { return [int64]$matches[1] }
  }
  return 0L
}

function Get-TreeFileCount {
  param([string]$Path)
  if (!(Test-Path -LiteralPath $Path)) { return 0 }
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return 0 }
  if (-not $item.PSIsContainer) { return 1 }
  $out = & "$env:SystemRoot\System32\robocopy.exe" $Path $env:TEMP /L /S /BYTES /XJ /R:0 /W:0 /NFL /NDL /NJH /NP 2>$null
  $rows = Get-RobocopySummary -Lines @($out)
  if ($rows.Count -ge 2) {
    $parts = ($rows[1] -split '\s+')
    if ($parts.Count -ge 1) { return [int]$parts[0] }
  }
  return 0
}

function Get-NormalPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-SafeId {
  param([string]$Owner, [string]$Path)
  $raw = "$Owner-$Path".ToLowerInvariant()
  $hash = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
  ).Replace('-', '').Substring(0, 10).ToLowerInvariant()
  $prefix = ($Owner -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 'candidate' }
  return "$prefix-$hash"
}

function Get-RunningProcessNames {
  $set = @{}
  Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
    $set[$_.ProcessName.ToLowerInvariant()] = $true
  }
  return $set
}

function New-Candidate {
  param(
    [string]$Path,
    [string]$Owner,
    [string]$Category,
    [ValidateSet('SAFE_DELETE','SAFE_IF_CLOSED','ADMIN_SAFE','CONFIRM_REQUIRED','MIGRATE_ONLY','NEVER_DELETE')]
    [string]$Risk,
    [ValidateSet('contents','delete_directory')]
    [string]$CleanupAction,
    [string[]]$ProcessNames = @(),
    [string]$Reason = ''
  )

  if (!(Test-Path -LiteralPath $Path)) { return $null }
  $full = Get-NormalPath $Path
  $bytes = Get-TreeBytes -Path $full
  if ($bytes -lt ($MinCandidateMB * 1MB)) { return $null }

  $processes = @($ProcessNames | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
  $matched = @($processes | Where-Object { $script:RunningProcesses.ContainsKey($_) })

  [pscustomobject]@{
    id = Get-SafeId -Owner $Owner -Path $full
    path = $full
    owner = $Owner
    category = $Category
    risk = $Risk
    cleanup_action = $CleanupAction
    size_mb = [math]::Round($bytes / 1MB, 2)
    size_gb = [math]::Round($bytes / 1GB, 3)
    process_names = @($processes)
    running = ($matched.Count -gt 0)
    matched_processes = @($matched)
    reason = $Reason
  }
}

function Get-DiskRows {
  $rows = @()
  foreach ($drive in $Drives) {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction SilentlyContinue
    if ($null -ne $disk) {
      $rows += [pscustomobject]@{
        drive = $disk.DeviceID
        volume = $disk.VolumeName
        size_gb = [math]::Round($disk.Size / 1GB, 2)
        free_gb = [math]::Round($disk.FreeSpace / 1GB, 2)
        used_gb = [math]::Round(($disk.Size - $disk.FreeSpace) / 1GB, 2)
        free_pct = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
      }
    }
  }
  $rows
}

function Get-TopLevelRows {
  if ($Mode -ne 'Deep') { return @() }
  $rows = @()
  foreach ($drive in $Drives) {
    $root = "$drive\"
    if (!(Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | ForEach-Object {
      $bytes = Get-TreeBytes -Path $_.FullName
      $rows += [pscustomobject]@{
        path = $_.FullName
        kind = 'top_level'
        size_gb = [math]::Round($bytes / 1GB, 3)
        size_mb = [math]::Round($bytes / 1MB, 1)
      }
    }
  }
  $rows | Sort-Object size_gb -Descending | Select-Object -First $Top
}

function Add-BrowserCandidates {
  param([System.Collections.Generic.List[object]]$Rows)

  $browserRoots = @(
    @{ Owner = 'Chrome'; Root = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'); Processes = @('chrome') },
    @{ Owner = 'Edge'; Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'); Processes = @('msedge','msedgewebview2') }
  )

  foreach ($browser in $browserRoots) {
    if (!(Test-Path -LiteralPath $browser.Root)) { continue }
    Get-ChildItem -LiteralPath $browser.Root -Directory -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -in @('Default','Guest Profile') -or $_.Name -like 'Profile *' } |
      ForEach-Object {
        foreach ($rel in @('Cache','Code Cache','GPUCache','ShaderCache','DawnWebGPUCache','GrShaderCache','Service Worker\CacheStorage')) {
          $row = New-Candidate -Path (Join-Path $_.FullName $rel) -Owner $browser.Owner -Category 'browser cache' -Risk 'SAFE_IF_CLOSED' -CleanupAction 'delete_directory' -ProcessNames $browser.Processes -Reason 'Rebuildable browser cache'
          if ($row) { $Rows.Add($row) | Out-Null }
        }
      }
  }

  $firefoxRoot = Join-Path $env:LOCALAPPDATA 'Mozilla\Firefox\Profiles'
  if (Test-Path -LiteralPath $firefoxRoot) {
    Get-ChildItem -LiteralPath $firefoxRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
      foreach ($rel in @('cache2','startupCache')) {
        $row = New-Candidate -Path (Join-Path $_.FullName $rel) -Owner 'Firefox' -Category 'browser cache' -Risk 'SAFE_IF_CLOSED' -CleanupAction 'delete_directory' -ProcessNames @('firefox') -Reason 'Rebuildable browser cache'
        if ($row) { $Rows.Add($row) | Out-Null }
      }
    }
  }
}

function Add-KnownAppCandidates {
  param([System.Collections.Generic.List[object]]$Rows)

  $known = @(
    @{ Path = (Join-Path $env:LOCALAPPDATA 'Doubao\User Data\Default\Code Cache'); Owner = 'Doubao'; Category = 'app cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('doubao') },
    @{ Path = (Join-Path $env:APPDATA 'thunder\Cache'); Owner = 'Thunder'; Category = 'app cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('thunder') },
    @{ Path = (Join-Path $env:APPDATA 'ep_pc_student\logs'); Owner = 'ep_pc_student'; Category = 'app logs'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('ep_pc_student') },
    @{ Path = (Join-Path $env:APPDATA 'WXDrive\logs'); Owner = 'WXDrive'; Category = 'app logs'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('wxdrive') },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'Netease\MailMaster\web\cache'); Owner = 'Netease MailMaster'; Category = 'app cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('mailmaster','netease') },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'DingTalk_133\Default\Cache'); Owner = 'DingTalk'; Category = 'app cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('dingtalk') },
    @{ Path = (Join-Path $env:APPDATA 'kingsoft\office6\cache'); Owner = 'WPS'; Category = 'app cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('wps','wpp','et','wpscloudsvr','wpsdoccenter') },
    @{ Path = (Join-Path $env:APPDATA 'Sangfor\aTrust\logs'); Owner = 'Sangfor aTrust'; Category = 'security app logs'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('atrust','atrustxtunnel','atrusttray','atrustagent') },
    @{ Path = (Join-Path $env:LOCALAPPDATA 'npm-cache'); Owner = 'npm'; Category = 'package cache'; Risk = 'SAFE_DELETE'; Action = 'delete_directory'; Processes = @() },
    @{ Path = (Join-Path $env:USERPROFILE '.cache\pip'); Owner = 'pip'; Category = 'package cache'; Risk = 'SAFE_DELETE'; Action = 'delete_directory'; Processes = @() },
    @{ Path = (Join-Path $env:USERPROFILE '.cache\puppeteer'); Owner = 'Puppeteer'; Category = 'browser binary cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('node') },
    @{ Path = (Join-Path $env:USERPROFILE '.cache\ms-playwright'); Owner = 'Playwright'; Category = 'browser binary cache'; Risk = 'SAFE_IF_CLOSED'; Action = 'delete_directory'; Processes = @('node') }
  )

  foreach ($item in $known) {
    $row = New-Candidate -Path $item.Path -Owner $item.Owner -Category $item.Category -Risk $item.Risk -CleanupAction $item.Action -ProcessNames $item.Processes -Reason 'Known rebuildable cache or log directory'
    if ($row) { $Rows.Add($row) | Out-Null }
  }
}

function Add-FixedCandidates {
  param([System.Collections.Generic.List[object]]$Rows)

  $fixed = @(
    @{ Path = (Join-Path $env:LOCALAPPDATA 'Temp'); Owner = 'Windows user temp'; Category = 'user temp'; Risk = 'SAFE_DELETE'; Action = 'contents'; Processes = @() },
    @{ Path = (Join-Path $env:SystemRoot 'Temp'); Owner = 'Windows temp'; Category = 'windows temp'; Risk = 'ADMIN_SAFE'; Action = 'contents'; Processes = @() },
    @{ Path = (Join-Path $env:ProgramData 'Microsoft\Windows\WER'); Owner = 'Windows Error Reporting'; Category = 'error reports'; Risk = 'ADMIN_SAFE'; Action = 'contents'; Processes = @() },
    @{ Path = (Join-Path $env:SystemRoot 'Minidump'); Owner = 'Windows Minidump'; Category = 'crash dumps'; Risk = 'ADMIN_SAFE'; Action = 'contents'; Processes = @() },
    @{ Path = (Join-Path $env:SystemRoot 'LiveKernelReports'); Owner = 'Windows LiveKernelReports'; Category = 'crash dumps'; Risk = 'ADMIN_SAFE'; Action = 'contents'; Processes = @() }
  )

  foreach ($drive in $Drives) {
    $fixed += @{ Path = "$drive\DeliveryOptimization"; Owner = 'Delivery Optimization'; Category = 'update cache'; Risk = 'ADMIN_SAFE'; Action = 'contents'; Processes = @() }
    $fixed += @{ Path = "$drive\WUDownloadCache"; Owner = 'Windows Update'; Category = 'update cache'; Risk = 'ADMIN_SAFE'; Action = 'contents'; Processes = @() }
  }

  foreach ($item in $fixed) {
    $row = New-Candidate -Path $item.Path -Owner $item.Owner -Category $item.Category -Risk $item.Risk -CleanupAction $item.Action -ProcessNames $item.Processes -Reason 'Fixed low-risk cleanup target'
    if ($row) { $Rows.Add($row) | Out-Null }
  }
}

function Add-DeepCandidates {
  param([System.Collections.Generic.List[object]]$Rows)
  if ($Mode -ne 'Deep') { return }

  $patterns = @('Cache','cache','Code Cache','GPUCache','ShaderCache','DawnWebGPUCache','GrShaderCache','CacheStorage','Temp','temp','Logs','logs','CrashDumps','SquirrelTemp','DynamicResourcePackage')

  # Deep 模式只扫描应用数据区，不扫描整个用户主目录。
  # 原实现把 $env:USERPROFILE 加入根目录，会递归命中
  # ~/.cache/huggingface、~/.cache/torch 等模型/推理缓存并被标为可清理，
  # 这类内容重建成本极高，必须排除。
  $roots = @($env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

  foreach ($root in $roots) {
    Get-ChildItem -LiteralPath $root -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
      $name = $_.Name
      @($patterns | Where-Object { $name -eq $_ }).Count -gt 0
    } | ForEach-Object {
      # 跳过模型/推理缓存等高重建成本目录
      $full = $_.FullName
      if ($full -match '\\(huggingface|torch|transformers|diffusers|ms-playwright|puppeteer|comfyui|models?)\\') { return }
      $row = New-Candidate -Path $full -Owner 'Discovered' -Category 'deep scan cache/log' -Risk 'SAFE_IF_CLOSED' -CleanupAction 'delete_directory' -ProcessNames @() -Reason 'Deep scan name match'
      if ($row) { $Rows.Add($row) | Out-Null }
    }
  }
}

function Get-InstalledApps {
  if (-not $IncludeInstalledApps) { return @() }
  $keys = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation |
    Sort-Object DisplayName |
    Select-Object -First 300
}

function Select-UniqueCandidates {
  param([object[]]$Candidates)
  $seen = @{}
  $selected = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in ($Candidates | Sort-Object size_mb -Descending)) {
    $key = $candidate.path.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $selected.Add($candidate) | Out-Null
  }
  return @($selected | Sort-Object size_mb -Descending)
}

function Get-SummaryRows {
  param([object[]]$Candidates)
  $Candidates | Group-Object risk | ForEach-Object {
    $mb = ($_.Group | Measure-Object size_mb -Sum).Sum
    [pscustomobject]@{
      risk = $_.Name
      items = $_.Count
      size_mb = [math]::Round($mb, 2)
      size_gb = [math]::Round($mb / 1024, 3)
    }
  } | Sort-Object size_mb -Descending
}

$script:RunningProcesses = Get-RunningProcessNames
$candidateRows = New-Object System.Collections.Generic.List[object]
Add-FixedCandidates -Rows $candidateRows
Add-BrowserCandidates -Rows $candidateRows
Add-KnownAppCandidates -Rows $candidateRows
Add-DeepCandidates -Rows $candidateRows

$candidates = Select-UniqueCandidates -Candidates @($candidateRows.ToArray())
$summary = @(Get-SummaryRows -Candidates $candidates)

if ([string]::IsNullOrWhiteSpace($PlanPath)) {
  $planDir = Join-Path $env:LOCALAPPDATA 'WindowsDiskCleaner\plans'
  New-Item -ItemType Directory -Force -Path $planDir | Out-Null
  $PlanPath = Join-Path $planDir ("windows-disk-cleaner-plan-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
} else {
  $planDir = Split-Path -Parent $PlanPath
  if ($planDir) { New-Item -ItemType Directory -Force -Path $planDir | Out-Null }
}

$result = [pscustomobject]@{
  generated_at = (Get-Date).ToString('s')
  mode = $Mode
  is_admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  plan_path = $PlanPath
  target_drives = @($Drives)
  disks = @(Get-DiskRows)
  top_level = @(Get-TopLevelRows)
  summary = @($summary)
  candidates = @($candidates)
  installed_apps = @(Get-InstalledApps)
}

try {
  $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $PlanPath -Encoding UTF8
} catch {
  Write-Warning ("Could not write plan file: {0}" -f $_.Exception.Message)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  'Disks'
  $result.disks | Format-Table -AutoSize
  ''
  'Cleanup summary'
  $result.summary | Format-Table -AutoSize
  ''
  'Top candidates'
  $result.candidates | Select-Object -First $Top owner,category,risk,running,size_mb,path | Format-Table -AutoSize
  ''
  "Plan saved: $PlanPath"
  'To clean from this plan:'
  "  .\clean_space.ps1 -PlanPath `"$PlanPath`""
  'To continue after closing apps:'
  "  .\clean_space.ps1 -PlanPath `"$PlanPath`" -Only SAFE_IF_CLOSED"
}
