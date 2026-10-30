param(
  [string[]]$Drives = @(),
  [string]$PlanPath = '',
  [int]$Top = 12,
  [int]$Depth = 2,
  # 仅对最大二级目录再次扫描，显示真实子目录大户，避免全盘四层扫描过慢。
  [switch]$DrillDown,
  [int]$DrillDownTop = 6,
  [string]$OutputDir = '',
  [switch]$NoHtml,
  [switch]$NoScan,
  [int]$TopFiles = 15,
  [int]$ScanTimeoutSec = 600
)

$ErrorActionPreference = 'Continue'

function Format-Size {
  param([double]$Bytes)
  if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
  if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
  if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
  return ('{0:N0} B' -f $Bytes)
}

function Get-TextSize {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
  return [int64]($Text.Length * 2)
}

function ConvertTo-Bytes {
  param([string]$SizeText, [string]$Unit)
  $n = 0.0
  if (-not [double]::TryParse($SizeText, [ref]$n)) { return 0L }
  switch ($Unit) {
    'B'   { return [int64]$n }
    'KiB' { return [int64]($n * 1024) }
    'MiB' { return [int64]($n * 1048576) }
    'GiB' { return [int64]($n * 1073741824) }
    'TiB' { return [int64]($n * 1099511627776) }
    'kB'  { return [int64]($n * 1000) }
    'MB'  { return [int64]($n * 1000000) }
    'GB'  { return [int64]($n * 1000000000) }
    'TB'  { return [int64]($n * 1000000000000) }
    default { return [int64]$n }
  }
}

function Find-GduPath {
  $cmd = Get-Command gdu -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\gdu.exe'),
    'C:\Program Files\gdu\gdu.exe'
  )
  $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
  if (Test-Path -LiteralPath $wingetRoot) {
    $candidates += @(Get-ChildItem -LiteralPath $wingetRoot -Recurse -Filter 'gdu*.exe' -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notmatch '\.(json|md|txt)$' } | Select-Object -ExpandProperty FullName)
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  return $null
}

function Invoke-GduText {
  param([string]$GduPath, [string[]]$GduArgs)
  $prev = [Console]::OutputEncoding
  try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $lines = & $GduPath @GduArgs 2>$null
  } catch {
    $lines = @()
  } finally {
    [Console]::OutputEncoding = $prev
  }
  return @($lines)
}

function Parse-GduTree {
  param([string[]]$Lines, [string]$DriveRoot, [int]$DirectoryDepth = $Depth)
  $rows = @()
  # 盘根形如 C:\ —— 用 TrimEnd('\') 会连盘符后的反斜杠一起去掉，
  # 导致 C:\ 本身被当成子目录。这里显式保留根路径形式。
  $rootTrimmed = $DriveRoot.TrimEnd('\')
  $prefix = $rootTrimmed + '\'
  foreach ($line in $Lines) {
    if ($line -match '^(\s*)([0-9][0-9,.]*)\s+(B|KiB|MiB|GiB|TiB|kB|MB|GB|TB)\s+(.+?)\s*$') {
      $size = ConvertTo-Bytes $matches[2] $matches[3]
      $path = $matches[4].Trim()
      if ($path -eq $rootTrimmed -or $path -eq $DriveRoot) { continue }
      if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
      $relative = $path.Substring($prefix.Length)
      # 深度 = 相对盘根的目录层数。G:\A 为 1，G:\A\B 为 2。
      $depth = ([regex]::Matches($relative, '\\')).Count + 1
      $isDir = $true
      if ($depth -le $DirectoryDepth) {
        $isDir = Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue
      }
      $rows += [pscustomobject]@{
        path = $path
        size = $size
        depth = $depth
        is_dir = $isDir
      }
    }
  }
  return @($rows)
}

function Get-DriveInventory {
  # 显式接收盘符列表。不要直接读取脚本级的同名 $Drives 变量：
  # 在 param() 块脚本里，同名变量在函数内会被解析为空，导致清单恒为空。
  param([string[]]$TargetDrives)
  $rows = @()
  foreach ($d in $TargetDrives) {
    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $d) -ErrorAction SilentlyContinue
    if ($disk) {
      $used = $disk.Size - $disk.FreeSpace
      $pct = if ($disk.Size -gt 0) { ($disk.FreeSpace / $disk.Size) * 100 } else { 0 }
      $rows += [pscustomobject]@{
        drive = $disk.DeviceID
        label = $disk.VolumeName
        size = [int64]$disk.Size
        used = [int64]$used
        free = [int64]$disk.FreeSpace
        free_pct = [math]::Round($pct, 1)
      }
    }
  }
  return @($rows)
}

function Test-HasPath {
  # 路径片段匹配。统一把分隔符规范成 / 后做子串判断，
  # 避免手写正则转义（尾随反斜杠等）导致的匹配异常。
  param([string]$Norm, [string[]]$Fragments)
  foreach ($f in $Fragments) {
    if ($Norm.Contains($f)) { return $true }
  }
  return $false
}

function Get-Category {
  param([string]$Path, [long]$Size)
  $n = ($Path -replace '\\', '/').ToLowerInvariant()
  # 取路径的最后一段，用于识别顶层目录名（如 C:\Projects、G:\ProjectW）
  $leaf = ''
  $idx = $n.LastIndexOf('/')
  if ($idx -ge 0 -and $idx -lt $n.Length - 1) { $leaf = $n.Substring($idx + 1) }

  # 引擎资产优先判定：UnrealEngine 目录下既有引擎本体也有项目资产，
  # 必须在通用规则之前命中，否则会被后面的规则误判。
  if (Test-HasPath $n @('/unrealengine/', '/unrealengine5/', '/ue5/', '/engine/source/', '/engine/content/', '/engine/intermediate/', '/deriveddatacache/', '/engine/binaries/')) { return '游戏引擎资产' }
  if (Test-HasPath $n @('/unity/', '/unityhub/', '/epic games/')) { return '游戏引擎资产' }

  if (Test-HasPath $n @('/models/', '/checkpoints/', '/loras/', '/diffusion_models/', '/unet/', '/vae/', '/clip/', '/text_encoders/')) { return 'AI 模型权重' }
  if ($n -match '\.(safetensors|ckpt|gguf|pth|onnx)$' -and $Size -gt 200MB) { return 'AI 模型权重' }
  if ((Test-HasPath $n @('/comfyui/', '/huggingface/', '/stable-diffusion-webui/', '/automatic1111/', '/invokeai/')) -and -not $n.Contains('/cache/')) { return 'AI 模型权重' }
  if (Test-HasPath $n @('/flux2models/', '/models/')) { return 'AI 模型权重' }

  if (Test-HasPath $n @('/pip/cache/', '/npm-cache/', '/npm/cache/', '/.npm/', '/.pnpm-store/', '/.yarn/', '/cargo/registry/', '/conda/pkgs/', '/.cache/pip/', '/.cache/uv/', '/nuget/packages/')) { return '包管理缓存' }
  if ((Test-HasPath $n @('/node_modules/', '/.cache/', '/target/', '/dist/', '/.next/', '/__pycache__/', '/.gradle/', '/.m2/')) -and -not (Test-HasPath $n @('/comfyui/', '/huggingface/')) -and $Size -lt 2GB) { return '构建依赖缓存' }

  if ((Test-HasPath $n @('/google/chrome/', '/microsoft/edge/', '/mozilla/firefox/', '/browser/')) -and (Test-HasPath $n @('/cache/', '/code cache/', '/gpucache/', '/shadercache/', '/grshadercache/', '/dawnwebgpucache/', '/cachestorage/', '/service worker/'))) { return '浏览器缓存' }
  if ((Test-HasPath $n @('/jetbrains/', '/rider/', '/pycharm/', '/webstorm/', '/goland/', '/clion/', '/datagrip/', '/intellij/', '/android studio/')) -and (Test-HasPath $n @('/caches/', '/cache/', '/index/', '/log/', '/tmp/', '/local history/', '/system/'))) { return 'IDE 缓存' }
  if ((Test-HasPath $n @('/vscode/', '/cursor/')) -and (Test-HasPath $n @('/cache/', '/cacheddata/', '/logs/', '/service worker/', '/dawnwebgpucache/'))) { return '编辑器缓存' }
  if ((Test-HasPath $n @('/wps/', '/kingsoft/', '/thunder/', '/dingtalk/', '/wxdrive/', '/doubao/', '/netease/', '/mailmaster/', '/wechat/', '/weixin/', '/wxwork/', '/sangfor/', '/atrust/', '/ep_pc_student/')) -and (Test-HasPath $n @('/cache/', '/log', '/tmp/', '/temp/', '/crash'))) { return '应用缓存与日志' }
  if ((Test-HasPath $n @('/comfyui/', '/stable-diffusion-webui/', '/automatic1111/')) -and (Test-HasPath $n @('/temp/', '/cache/', '/output/', '/preview/'))) { return 'AI 生成缓存' }

  # Godot / Unity 项目数据
  if (Test-HasPath $n @('/.godot/', '/godot/')) { return '引擎项目缓存' }
  if (Test-HasPath $n @('/sandbox/', '/ugc/', '/ugc_devsandbox/', '/experiments/')) { return '项目工作区' }

  if ($n.Contains('/.git/') -or $n.Contains('/objects/pack/')) { return 'Git 仓库数据' }
  if ($n -match '\.(vhdx|vmdk|vdi)$' -or $n.Contains('/docker/') -or $n.Contains('/wsl/')) { return '虚拟磁盘' }
  if ($n.Contains('$recycle.bin')) { return '回收站' }
  if (Test-HasPath $n @('/temp/', '/tmp/', '/tempstate/')) { return '临时文件' }
  if (Test-HasPath $n @('/crashdumps/', '/crash dumps/', '/minidump/', '/livekernelreports/', '/wer/')) { return '崩溃转储与错误报告' }

  # 系统与应用安装目录
  if ($n.Contains('/program files/') -or $n.Contains('/programdata/') -or $n.Contains('/windows/') -or
      $n.Contains('/autodesk/') -or $n.Contains('/drivers/') -or $n.Contains('/recovery/') -or
      $n.Contains('/system volume information/')) { return '系统与软件' }

  # 顶层目录名判断：这类目录本身就是项目/素材集合
  if ($leaf -match '^(projects?|myprojs?|myproj|projecta|projectd|projectw|projectwg|aifvg|aivg|aiengine|videoGen|videoGenArchive|videoGenWork)$') { return '项目目录' }
  if ($leaf -match '^(mydocument|myfile|mydoc|myfiles|mydownload|mydocuments)$') { return '个人资料' }
  if ($leaf -match '^(mys?oftware|mytools|tools|software|ue)$') { return '软件安装' }
  if ($leaf -match '^(wan2gp|flux2models|models?)$') { return 'AI 模型权重' }

  # 路径中段含项目名（多级目录）
  if (Test-HasPath $n @('/projects/', '/myprojs/', '/myproj/', '/projecta/', '/projectd/', '/projectw/', '/projectwg/', '/videogen/', '/aifvg/')) { return '项目目录' }
  if ($n.Contains('/appdata/')) { return '用户配置与缓存' }
  if ($leaf -eq 'users' -or (Test-HasPath $n @('/users/'))) { return '用户数据' }

  # 常见大目录名的兜底归类，避免全部落进"其他"导致报告失去指导意义
  if (Test-HasPath $n @('/assets/', '/content/', '/resources/', '/art/', '/textures/')) { return '项目资产' }
  if (Test-HasPath $n @('/src/', '/source/', '/code/', '/scripts/', '/addons/', '/plugins/')) { return '源代码' }
  if (Test-HasPath $n @('/docs/', '/documentation/')) { return '文档' }

  return '其他'
}

function Get-Advice {
  param([string]$Category)
  switch ($Category) {
    'AI 模型权重'      { return @{ action = '迁移到其他盘'; risk = '不建议删除'; rebuild = '极高'; detail = '删除后需重新下载，数十 GB 的时间与流量成本不可接受。优先迁移而非清理。' } }
    'AI 生成缓存'      { return @{ action = '清理'; risk = '低'; rebuild = '极低'; detail = 'ComfyUI 等工具的输出与预览中间产物，可重建。' } }
    '包管理缓存'       { return @{ action = '清理'; risk = '低'; rebuild = '低'; detail = '包管理器按需重新下载，建议走官方清理命令而非手删。' } }
    '构建依赖缓存'     { return @{ action = '按需清理'; risk = '低'; rebuild = '中'; detail = 'node_modules 等可重装，但重新安装需时间与带宽。' } }
    '浏览器缓存'       { return @{ action = '先关闭浏览器再清理'; risk = '低'; rebuild = '低'; detail = '浏览器会自行重建；运行中清理可能导致页面异常或标签页崩溃。' } }
    'IDE 缓存'         { return @{ action = '先关闭 IDE 再清理'; risk = '低'; rebuild = '中'; detail = 'Rider/VS Code 会重建索引，首次打开会明显变慢。' } }
    '编辑器缓存'       { return @{ action = '先关闭编辑器再清理'; risk = '低'; rebuild = '低'; detail = 'Cursor/VS Code 的缓存与日志，可重建。' } }
    '应用缓存与日志'   { return @{ action = '清理日志，缓存按需'; risk = '低'; rebuild = '低'; detail = '建议优先清日志；企业微信/钉钉等缓存需在应用内清理以免破坏索引。' } }
    'Git 仓库数据'     { return @{ action = '用 git gc 压缩，不要手删'; risk = '中'; rebuild = '低'; detail = '直接删 .git/objects 会损坏仓库，正确做法是 git gc --aggressive。' } }
    '虚拟磁盘'         { return @{ action = '专用工具处理'; risk = '高'; rebuild = '高'; detail = '需先 wsl --shutdown 或停止 Docker，再压缩 vhdx / docker system prune。' } }
    '游戏引擎资产'     { return @{ action = '归档或卸载'; risk = '高'; rebuild = '极高'; detail = '引擎与 DerivedDataCache 体积巨大，建议用启动器卸载或迁移到数据盘。' } }
    '引擎项目缓存'     { return @{ action = '按需清理'; risk = '中'; rebuild = '中'; detail = 'Godot 导入缓存可重建，删除后首次打开项目会重新导入。' } }
    '项目工作区'       { return @{ action = '人工确认'; risk = '中'; rebuild = '未知'; detail = '可能是实验分支或临时工作区，确认不再使用后再处理。' } }
    '项目资产'         { return @{ action = '归档或迁移'; risk = '高'; rebuild = '高'; detail = '项目素材通常不可重建，建议迁移到数据盘而非删除。' } }
    '源代码'           { return @{ action = '保留'; risk = '高'; rebuild = '极高'; detail = '源代码必须保留。若占用大，说明有大量生成物混在源码目录。' } }
    '文档'             { return @{ action = '保留'; risk = '低'; rebuild = '高'; detail = '文档体积小，不值得清理。' } }
    '系统与软件'       { return @{ action = '用官方工具处理'; risk = '高'; rebuild = '高'; detail = '程序安装目录，不要手动删除；用应用自带卸载或磁盘清理工具。' } }
    '用户配置与缓存'   { return @{ action = '逐项甄别'; risk = '中'; rebuild = '中'; detail = '混有配置与缓存，需按应用判断，多数可安全清理缓存部分。' } }
    '用户数据'         { return @{ action = '人工确认'; risk = '中'; rebuild = '未知'; detail = '用户主目录下的数据，通常不该自动清理。' } }
    '个人资料'         { return @{ action = '保留'; risk = '高'; rebuild = '极高'; detail = '个人文档与素材，不应自动清理。建议迁移到外部存储。' } }
    '软件安装'         { return @{ action = '用官方卸载'; risk = '高'; rebuild = '高'; detail = '应用安装目录，用卸载器移除，不要手删。' } }
    '项目目录'         { return @{ action = '保留或迁移'; risk = '高'; rebuild = '极高'; detail = '项目本体。建议整体迁移到空间更充裕的盘。' } }
    '回收站'           { return @{ action = '确认后清空'; risk = '中'; rebuild = '不适用'; detail = '回收站里可能还有你想恢复的文件，清空前请确认。' } }
    '临时文件'         { return @{ action = '清理'; risk = '低'; rebuild = '极低'; detail = '系统与应用的临时产物，最安全的一类。' } }
    '崩溃转储与错误报告' { return @{ action = '清理'; risk = '低'; rebuild = '极低'; detail = '崩溃现场文件，若需排查问题可先留一份。' } }
    default             { return @{ action = '人工判断'; risk = '未知'; rebuild = '未知'; detail = '无法自动判定用途，需你确认后再决定。' } }
  }
}

function Get-Tension {
  param([double]$FreePct)
  if ($FreePct -lt 5) { return @{ label = '严重告警'; color = 'red' } }
  if ($FreePct -lt 10) { return @{ label = '告警'; color = 'amber' } }
  if ($FreePct -lt 20) { return @{ label = '注意'; color = 'yellow' } }
  return @{ label = '正常'; color = 'teal' }
}

function Escape-Md {
  param([string]$Text)
  if ($null -eq $Text) { return '' }
  return ($Text -replace '\|', '\|')
}

function Escape-Html {
  param([string]$Text)
  if ($null -eq $Text) { return '' }
  return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

# ---------------------------------------------------------------- 采集数据

$gduPath = Find-GduPath

# 未显式指定盘符时，扫描所有已就绪的固定盘
# 注意：命令行传入 -Drives C:,G: 时 PowerShell 会把它当成单个字符串 "C:,G:"，
# 这里统一拆分成数组，否则后续所有按盘遍历都会退化成单个无效盘符。
$normalized = @()
foreach ($d in @($Drives)) {
  foreach ($part in ([string]$d -split ',')) {
    $t = $part.Trim()
    if ($t) { $normalized += $t }
  }
}
$Drives = @($normalized)

if ($Drives.Count -eq 0) {
  $Drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
    Sort-Object DeviceID | Select-Object -ExpandProperty DeviceID)
}

$inventory = Get-DriveInventory -TargetDrives $Drives

$treeRows = @()
$fileRows = @()
$drillRows = @()
$engineNote = ''

if ($gduPath -and -not $NoScan) {
  # gdu 的 -t（大文件列表）会替换目录树输出，无法一次拿到两者。
  # 两条命令各自都要完整遍历磁盘，因此并行执行，把总耗时压到单次扫描量级。
  #
  # 注意：不用 Start-Job。PowerShell 后台 Job 会把 gdu 的输出拆成
  # 包装过的对象流，实测会导致解析层拿不到原始文本行。
  # 这里改为直接启动 gdu 进程并把输出重定向到临时文件，再读取解析。
  # 启动 gdu 子进程并把 stdout 重定向到临时文件。
  #
  # 两个坑：
  # 1) 不用 Start-Process —— 它会构造进程环境字典，而当前环境里同时存在
  #    HTTPS_PROXY 与 https_proxy（大小写不同的重复键），.NET 字典构建会直接
  #    抛 "已添加项。字典中的关键字" 异常。
  # 2) 不用 BeginOutputReadLine 异步读 —— 进程退出时事件队列里仍有未派发的
  #    数据，实测会丢掉绝大部分输出（1TB 盘只剩 2 行）。
  #    改为重定向到文件后同步读取，稳定且无竞态。
  $jobs = @()
  $tmpDir = Join-Path $env:TEMP ('wdc-report-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

  function Start-GduProcess {
    param([string]$Exe, [string[]]$ExeArgs, [string]$OutFile, [string]$ErrFile)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($ExeArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    return [pscustomobject]@{ proc = $proc; outFile = $OutFile; errFile = $ErrFile }
  }

  function Complete-GduProcess {
    # 异步持续读取两个管道，避免输出填满缓冲区后子进程无法退出。
    # 到时后终止本次 gdu 扫描并保留已经读到的结果，让报告仍可生成。
    param([object]$Handle, [int]$TimeoutSec)
    $stdoutTask = $Handle.proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $Handle.proc.StandardError.ReadToEndAsync()
    $timedOut = -not $Handle.proc.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)
    if ($timedOut) {
      Write-Warning ("扫描超时（{0} 秒）：{1}" -f $TimeoutSec, $Handle.proc.StartInfo.Arguments)
      try { $Handle.proc.Kill() } catch { }
      $Handle.proc.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [System.IO.File]::WriteAllText($Handle.outFile, $stdout, (New-Object System.Text.UTF8Encoding($false)))
    if ($stderr) { [System.IO.File]::WriteAllText($Handle.errFile, $stderr, (New-Object System.Text.UTF8Encoding($false))) }
    return [pscustomobject]@{ exit_code = $Handle.proc.ExitCode; timed_out = $timedOut }
  }

  function Read-GduFiles {
    param([string]$OutFile, [string]$Drive)
    foreach ($line in @(Get-Content -LiteralPath $OutFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ($line -match '^\s*([0-9][0-9,.]*)\s+(B|KiB|MiB|GiB|TiB|kB|MB|GB|TB)\s+(.+?)\s*$') {
        $script:fileRows += [pscustomobject]@{
          path = $matches[3].Trim()
          size = ConvertTo-Bytes $matches[1] $matches[2]
          drive = $Drive
        }
      }
    }
  }

  # 同一盘的两次扫描（目录树 + 大文件）不能并发：gdu 两个实例同时扫同一盘
  # 会竞争本地缓存，其中一个可能静默失败输出空结果（实测偶发）。
  # 因此按"阶段"并行：第一阶段所有盘扫目录树，第二阶段所有盘扫大文件。
  # 盘与盘之间仍然并行，总耗时不变。

  # 阶段 1：目录树
  $treeHandles = @()
  foreach ($drive in $inventory) {
    $root = $drive.drive + '\'
    $treeHandles += [pscustomobject]@{
      drive = $drive.drive
      h = Start-GduProcess -Exe $gduPath -ExeArgs @('-n', '--depth', $Depth, $root) `
        -OutFile (Join-Path $tmpDir ($drive.drive.TrimEnd(':') + '-tree.txt')) `
        -ErrFile (Join-Path $tmpDir ($drive.drive.TrimEnd(':') + '-tree.err'))
    }
  }
  foreach ($j in $treeHandles) {
    Write-Host ("  扫描 {0} 盘目录结构..." -f $j.drive)
    $null = Complete-GduProcess -Handle $j.h -TimeoutSec $ScanTimeoutSec
  }

  # 阶段 2：大文件
  $fileHandles = @()
  foreach ($drive in $inventory) {
    $root = $drive.drive + '\'
    $fileHandles += [pscustomobject]@{
      drive = $drive.drive
      h = Start-GduProcess -Exe $gduPath -ExeArgs @('-n', '-t', $TopFiles, $root) `
        -OutFile (Join-Path $tmpDir ($drive.drive.TrimEnd(':') + '-files.txt')) `
        -ErrFile (Join-Path $tmpDir ($drive.drive.TrimEnd(':') + '-files.err'))
    }
  }
  foreach ($j in $fileHandles) {
    Write-Host ("  扫描 {0} 盘大文件..." -f $j.drive)
    $null = Complete-GduProcess -Handle $j.h -TimeoutSec $ScanTimeoutSec
  }

  # 汇总解析
  foreach ($j in $treeHandles) {
    if (Test-Path -LiteralPath $j.h.outFile) {
      $lines = @(Get-Content -LiteralPath $j.h.outFile -Encoding UTF8 -ErrorAction SilentlyContinue)
      $treeRows += Parse-GduTree -Lines $lines -DriveRoot ($j.drive + '\')
    }
  }
  foreach ($j in $fileHandles) {
    if (Test-Path -LiteralPath $j.h.outFile) {
      Read-GduFiles -OutFile $j.h.outFile -Drive $j.drive
    }
  }

  # 细查模式：只对最大的二级目录重新下钻。例如 C:\Users\<用户> 会展开到
  # AppData、缓存和模型等真实大户，而不会把整个 C: 的每个小目录都载入报告。
  if ($DrillDown) {
    $targets = @($treeRows | Where-Object { $_.is_dir -and $_.depth -eq 2 -and $_.size -ge 1GB } |
      Sort-Object size -Descending | Select-Object -First ([Math]::Max(1, $DrillDownTop)))
    foreach ($target in $targets) {
      $drive = $target.path.Substring(0, 2)
      $safeName = ($target.path -replace '[:\\]', '_')
      Write-Host ('  深入扫描：' + $target.path)
      $h = Start-GduProcess -Exe $gduPath -ExeArgs @('-n', '--depth', 3, $target.path) `
        -OutFile (Join-Path $tmpDir ($safeName + '-drill.txt')) `
        -ErrFile (Join-Path $tmpDir ($safeName + '-drill.err'))
      $null = Complete-GduProcess -Handle $h -TimeoutSec $ScanTimeoutSec
      if (Test-Path -LiteralPath $h.outFile) {
        $lines = @(Get-Content -LiteralPath $h.outFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        $drillRows += Parse-GduTree -Lines $lines -DriveRoot ($drive + '\') -DirectoryDepth 8
      }
    }
  }

  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

  $engineNote = 'gdu ' + ((& $gduPath --version 2>$null | Select-Object -First 1) -replace '^Version:\s*', '')
} elseif ($NoScan) {
  $engineNote = '未扫描磁盘（-NoScan），仅基于清理计划分析'
} else {
  $engineNote = 'gdu 未安装，仅基于清理计划分析'
}

# 读取清理计划
if (-not $PlanPath) {
  $planDir = Join-Path $env:LOCALAPPDATA 'WindowsDiskCleaner\plans'
  if (Test-Path -LiteralPath $planDir) {
    $latest = Get-ChildItem -LiteralPath $planDir -Filter '*.json' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $PlanPath = $latest.FullName }
  }
}

$plan = $null
if ($PlanPath -and (Test-Path -LiteralPath $PlanPath)) {
  try { $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json } catch { $plan = $null }
}

$planCandidates = @()
if ($plan) { $planCandidates = @($plan.candidates) }

# 大项聚合（来自 gdu 树），按分类统计
# 只取深度 2 的条目：深度 1 是盘根下的顶层目录，深度 3+ 会与父目录重复计数。
$bigItems = @()
foreach ($drive in $inventory) {
  $prefix = $drive.drive + '\'
  $driveDirs = @($treeRows | Where-Object { $_.is_dir -and $_.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $_.depth -le 2 -and $_.size -gt 1GB } |
    Sort-Object size -Descending | Select-Object -First 40)
  foreach ($d in $driveDirs) {
    $cat = Get-Category -Path $d.path -Size $d.size
    $adv = Get-Advice -Category $cat
    $bigItems += [pscustomobject]@{
      path = $d.path
      size = $d.size
      drive = $drive.drive
      depth = $d.depth
      category = $cat
      action = $adv.action
      risk = $adv.risk
      rebuild = $adv.rebuild
      detail = $adv.detail
    }
  }
}

$byCategory = @()
$grouped = $bigItems | Group-Object category
foreach ($g in $grouped) {
  $total = ($g.Group | Measure-Object size -Sum).Sum
  $byCategory += [pscustomobject]@{
    category = $g.Name
    total = [int64]$total
    count = $g.Count
    action = (Get-Advice -Category $g.Name).action
    risk = (Get-Advice -Category $g.Name).risk
  }
}
$byCategory = @($byCategory | Sort-Object total -Descending)

# 计划项按风险分组
$planGroups = @{}
foreach ($tier in @('SAFE_DELETE', 'SAFE_IF_CLOSED', 'ADMIN_SAFE', 'CONFIRM_REQUIRED', 'MIGRATE_ONLY', 'NEVER_DELETE')) {
  $items = @($planCandidates | Where-Object { $_.risk -eq $tier } | Sort-Object size_mb -Descending)
  $planGroups[$tier] = @($items)
}

$tierMeta = @{
  'SAFE_DELETE'      = @{ title = '立即可清理'; note = '无需关闭任何软件，直接删除不影响使用'; color = 'teal' }
  'SAFE_IF_CLOSED'   = @{ title = '需先关闭软件'; note = '关闭对应应用后再清理，否则可能损坏缓存索引'; color = 'amber' }
  'ADMIN_SAFE'       = @{ title = '需管理员权限'; note = '系统级目录，建议用官方维护工具处理'; color = 'blue' }
  'CONFIRM_REQUIRED' = @{ title = '需你确认'; note = '无法自动判定用途，逐项确认后再处理'; color = 'red' }
  'MIGRATE_ONLY'     = @{ title = '仅建议迁移'; note = '不应删除，建议迁移到其他盘'; color = 'purple' }
  'NEVER_DELETE'     = @{ title = '永不删除'; note = '系统组件或业务数据，工具已自动排除'; color = 'gray' }
}

# 每个风险档位对应的推荐操作说明，让报告能直接指导行动
$tierAction = @{
  'SAFE_DELETE'      = @'
- 临时文件（Temp）：系统与应用自动生成，可直接删除
- 包管理缓存：建议走官方命令，例如 `npm cache clean --force`、`pip cache purge`
'@
  'SAFE_IF_CLOSED'   = @'
- 浏览器缓存：先完全退出 Chrome / Edge（注意托盘图标），再清理对应 Profile 下的缓存目录
- Puppeteer / Playwright 浏览器内核：删除后需要重新下载约 300 MB，不要在 node 进程运行时删
'@
  'ADMIN_SAFE'       = @'
- `C:\Windows\Temp`：需管理员权限，建议用「设置 → 系统 → 存储 → 临时文件」清理
- 崩溃转储 / 错误报告：先用「设置 → 系统 → 存储 → 临时文件」中的系统错误内存转储清理
'@
  'CONFIRM_REQUIRED' = @'
- 逐项打开确认内容后再决定，不要批量删除
- 确认无误可先备份到其他盘再删
'@
  'MIGRATE_ONLY'     = @'
- 用 `migrate_app_data.ps1` 迁移到空间更充裕的盘，它会建立目录联接保持原路径可用
- 迁移前务必关闭对应应用，并保留回滚备份
'@
}

$totalSafe = 0L
foreach ($t in @('SAFE_DELETE', 'SAFE_IF_CLOSED', 'ADMIN_SAFE')) {
  foreach ($i in $planGroups[$t]) { $totalSafe += [int64]($i.size_mb * 1MB) }
}

# ---------------------------------------------------------------- 生成报告

if (-not $OutputDir) {
  $OutputDir = Join-Path $env:LOCALAPPDATA 'WindowsDiskCleaner\reports'
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$mdPath = Join-Path $OutputDir "disk-report-$stamp.md"
$htmlPath = Join-Path $OutputDir "disk-report-$stamp.html"

$md = New-Object System.Text.StringBuilder
function Add-Md { param([string]$Text) [void]$md.AppendLine($Text) }

Add-Md '# 磁盘空间分析报告'
Add-Md ''
Add-Md ('- 生成时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
Add-Md ('- 扫描引擎：' + $engineNote)
if ($PlanPath) { Add-Md ('- 清理计划：`' + $PlanPath + '`') }
Add-Md ''

# 结论速览
Add-Md '## 一、结论速览'
Add-Md ''
$tight = @($inventory | Where-Object { $_.free_pct -lt 10 })
foreach ($d in $tight) {
  $t = Get-Tension $d.free_pct
  Add-Md ("- **{0} 盘已告警**：剩余 {1}（{2}%），已进入需要立即处理的区间。" -f $d.drive, (Format-Size $d.free), $d.free_pct)
}
if ($planGroups['SAFE_DELETE'].Count -gt 0) {
  $sum = 0L
  foreach ($i in $planGroups['SAFE_DELETE']) { $sum += [int64]($i.size_mb * 1MB) }
  Add-Md ("- **可直接释放约 {0}**：临时文件与包管理缓存，无需关闭任何软件。" -f (Format-Size $sum))
}
if ($planGroups['SAFE_IF_CLOSED'].Count -gt 0) {
  $sum = 0L
  foreach ($i in $planGroups['SAFE_IF_CLOSED']) { $sum += [int64]($i.size_mb * 1MB) }
  Add-Md ("- **关闭软件后还能释放约 {0}**：浏览器与 IDE 缓存。" -f (Format-Size $sum))
}
$migrate = @($byCategory | Where-Object { $_.risk -eq '不建议删除' })
if ($migrate.Count -gt 0) {
  $sum = 0L
  foreach ($m in $migrate) { $sum += $m.total }
  Add-Md ("- **约 {0} 属于「不建议删除」**：AI 模型权重与引擎资产，正确做法是迁移到数据盘，而不是清理。" -f (Format-Size $sum))
}
$biggest = @($bigItems | Sort-Object size -Descending | Select-Object -First 1)
if ($biggest.Count -gt 0) {
  Add-Md ("- **单笔最大占用**：`{0}`（{1}）。" -f $biggest[0].path, (Format-Size $biggest[0].size))
}
Add-Md ''

# 磁盘总览
Add-Md '## 二、磁盘总览'
Add-Md ''
Add-Md '| 盘符 | 卷标 | 容量 | 已用 | 剩余 | 剩余占比 | 状态 |'
Add-Md '| --- | --- | ---: | ---: | ---: | ---: | --- |'
foreach ($d in $inventory) {
  $t = Get-Tension $d.free_pct
  Add-Md ("| {0} | {1} | {2} | {3} | {4} | {5}% | {6} |" -f $d.drive, $d.label, (Format-Size $d.size), (Format-Size $d.used), (Format-Size $d.free), $d.free_pct, $t.label)
}
Add-Md ''

# 空间大头
Add-Md '## 三、空间去哪了'
Add-Md ''
if ($byCategory.Count -gt 0) {
  Add-Md '### 3.1 按性质归类'
  Add-Md ''
  Add-Md '| 性质 | 合计 | 项目数 | 建议动作 | 风险 |'
  Add-Md '| --- | ---: | ---: | --- | --- |'
  foreach ($c in $byCategory) {
    Add-Md ("| {0} | {1} | {2} | {3} | {4} |" -f $c.category, (Format-Size $c.total), $c.count, $c.action, $c.risk)
  }
  Add-Md ''
  Add-Md '> 同一盘内父子目录会分别计入，因此合计略大于实际占用，仅用于判断哪类内容占大头。'
  Add-Md ''
}

Add-Md '### 3.2 各盘顶层目录'
Add-Md ''
foreach ($d in $inventory) {
  $dirs = @($treeRows | Where-Object { $_.is_dir -and $_.path.StartsWith(($d.drive + '\'), [StringComparison]::OrdinalIgnoreCase) -and $_.depth -eq 1 } |
    Sort-Object size -Descending | Select-Object -First $Top)
  if ($dirs.Count -eq 0) { continue }
  Add-Md ("**{0} 盘**" -f $d.drive)
  Add-Md ''
  Add-Md '| 目录 | 占用 | 性质 |'
  Add-Md '| --- | ---: | --- |'
  foreach ($x in $dirs) {
    $cat = Get-Category -Path $x.path -Size $x.size
    Add-Md ("| `{0}` | {1} | {2} |" -f (Escape-Md $x.path), (Format-Size $x.size), $cat)
  }
  Add-Md ''
}

$deepRows = @($treeRows | Where-Object { $_.is_dir -and $_.depth -eq 2 -and $_.size -gt 3GB } | Sort-Object size -Descending | Select-Object -First 10)
if ($deepRows.Count -gt 0) {
  Add-Md '### 3.3 二级目录大户'
  Add-Md ''
  Add-Md '| 目录 | 占用 | 性质 | 建议动作 |'
  Add-Md '| --- | ---: | --- | --- |'
  foreach ($x in $deepRows) {
    $cat = Get-Category -Path $x.path -Size $x.size
    $adv = Get-Advice -Category $cat
    Add-Md ("| `{0}` | {1} | {2} | {3} |" -f (Escape-Md $x.path), (Format-Size $x.size), $cat, $adv.action)
  }
  Add-Md ''
}

$mdFiles = @($fileRows | Where-Object { $_ -and $null -ne $_.PSObject.Properties['size'] })
if ($mdFiles.Count -gt 0) {
  Add-Md '### 3.4 单个大文件'
  Add-Md ''
  Add-Md '| 文件 | 占用 | 性质 |'
  Add-Md '| --- | ---: | --- |'
  foreach ($f in @($mdFiles | Sort-Object size -Descending | Select-Object -First 10)) {
    $cat = Get-Category -Path $f.path -Size $f.size
    Add-Md ("| `{0}` | {1} | {2} |" -f (Escape-Md $f.path), (Format-Size $f.size), $cat)
  }
  Add-Md ''
}

# 清理建议
Add-Md '## 四、清理建议'
Add-Md ''
$order = @('SAFE_DELETE', 'SAFE_IF_CLOSED', 'ADMIN_SAFE', 'CONFIRM_REQUIRED', 'MIGRATE_ONLY')
$idx = 0
foreach ($tier in $order) {
  $items = @($planGroups[$tier])
  $meta = $tierMeta[$tier]
  if ($items.Count -eq 0) { continue }
  $idx++
  $sum = 0L
  foreach ($i in $items) { $sum += [int64]($i.size_mb * 1MB) }
  Add-Md ("### 4.{0} {1}（{2}）" -f $idx, $meta.title, (Format-Size $sum))
  Add-Md ''
  Add-Md $meta.note
  Add-Md ''
  Add-Md '| 占用 | 归属 | 类别 | 路径 |'
  Add-Md '| ---: | --- | --- | --- |'
  foreach ($i in @($items | Select-Object -First 15)) {
    Add-Md ("| {0} | {1} | {2} | `{3}` |" -f (Format-Size ([int64]($i.size_mb * 1MB))), (Escape-Md $i.owner), (Escape-Md $i.category), (Escape-Md $i.path))
  }
  if ($items.Count -gt 15) {
    Add-Md ''
    Add-Md ("其余 {0} 项未列出。" -f ($items.Count - 15))
  }
  Add-Md ''
  if ($tierAction.ContainsKey($tier)) {
    Add-Md '**怎么清**'
    Add-Md ''
    Add-Md $tierAction[$tier]
    Add-Md ''
  }
}

# 大额但不可自动清理
$manual = @($bigItems | Where-Object { $_.risk -ne '低' -and $_.size -gt 2GB } | Sort-Object size -Descending | Select-Object -First 12)
if ($manual.Count -gt 0) {
  Add-Md '## 五、需要你决策的大额项目'
  Add-Md ''
  Add-Md '这些项目体量大但不该直接删除，工具已自动排除在清理范围之外。'
  Add-Md ''
  Add-Md '| 占用 | 性质 | 建议动作 | 重建成本 | 路径 |'
  Add-Md '| ---: | --- | --- | --- | --- |'
  foreach ($m in $manual) {
    Add-Md ("| {0} | {1} | {2} | {3} | `{4}` |" -f (Format-Size $m.size), $m.category, $m.action, $m.rebuild, (Escape-Md $m.path))
  }
  Add-Md ''
  Add-Md '**处理原则**'
  Add-Md ''
  Add-Md '- 模型权重、引擎资产、项目本体：迁移到 D/E 数据盘，用目录联接保持原路径可用'
  Add-Md '- Git 仓库数据：用 `git gc --aggressive` 压缩，不要手删 `.git/objects`'
  Add-Md '- 虚拟磁盘：先 `wsl --shutdown` 或停 Docker，再压缩 vhdx'
  Add-Md '- 回收站：确认没有需要恢复的文件后再清空'
  Add-Md ''
}

# 执行步骤
Add-Md '## 六、执行步骤'
Add-Md ''
Add-Md '先跑 DryRun 确认清单，确认无误再实删：'
Add-Md ''
Add-Md '```powershell'
Add-Md '# 1. 预演，不删除任何文件'
if ($PlanPath) {
  Add-Md ('clean_space.ps1 -PlanPath "' + $PlanPath + '" -DryRun')
} else {
  Add-Md 'scan_space.ps1 -Drives C: -Mode Fast'
}
Add-Md ''
Add-Md '# 2. 只清低风险项（无需关软件）'
if ($PlanPath) {
  Add-Md ('clean_space.ps1 -PlanPath "' + $PlanPath + '" -Only SAFE_DELETE')
}
Add-Md ''
Add-Md '# 3. 关掉 Chrome / Edge / IDE 后，再清这一批'
if ($PlanPath) {
  Add-Md ('clean_space.ps1 -PlanPath "' + $PlanPath + '" -Only SAFE_IF_CLOSED')
}
Add-Md '```'
Add-Md ''
Add-Md '保留回收站内容，避免误删不可恢复；确需清空时加 `-ClearRecycleBin`。'
Add-Md ''

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($mdPath, $md.ToString(), $utf8Bom)

# ---------------------------------------------------------------- HTML 报告

if (-not $NoHtml) {
  $html = New-Object System.Text.StringBuilder
  function Add-H { param([string]$Text) [void]$html.AppendLine($Text) }

  # 统一色板：内容性质 → 颜色。全篇图表用同一映射，看颜色即知性质。
  $script:catPalette = @{
    'AI 模型权重' = '#c39bf2'; '游戏引擎资产' = '#f0a55a'; '引擎项目缓存' = '#e8c46b'
    '项目目录' = '#6aa8f0'; '项目资产' = '#9fd0f5'; '项目工作区' = '#8a97a8'
    '源代码' = '#8fd4a8'; '个人资料' = '#f093ab'; '用户数据' = '#f2b8c6'
    '用户配置与缓存' = '#d9a8f0'; '回收站' = '#ef5f5f'; '包管理缓存' = '#5dcaa5'
    '构建依赖缓存' = '#7fd8c8'; '浏览器缓存' = '#5fb8d8'; 'IDE 缓存' = '#e0c35a'
    '编辑器缓存' = '#c8d85a'; '应用缓存与日志' = '#e8875e'; 'AI 生成缓存' = '#b678e0'
    'Git 仓库数据' = '#f07178'; '虚拟磁盘' = '#c78af0'; '临时文件' = '#9aa4b0'
    '崩溃转储与错误报告' = '#7f8794'; '系统与软件' = '#a8b0bc'; '软件安装' = '#b8c0cc'
    '文档' = '#c8d0da'; '其他' = '#565d68'
  }
  function Get-CatColor { param([string]$Category)
    if ($script:catPalette.ContainsKey([string]$Category)) { return $script:catPalette[[string]$Category] }
    return '#565d68'
  }
  function Get-Leaf { param([string]$Path)
    $p = $Path.TrimEnd('\')
    $i = $p.LastIndexOf('\')
    if ($i -ge 0 -and $i -lt $p.Length - 1) { return $p.Substring($i + 1) }
    return $p
  }
  function Get-ExplorerUrl {
    param([string]$Path, [switch]$OpenParent)
    $target = $Path
    if ($OpenParent -and -not [string]::IsNullOrWhiteSpace($Path)) {
      $target = Split-Path -Path $Path -Parent
    }
    if ([string]::IsNullOrWhiteSpace($target) -or -not [System.IO.Path]::IsPathRooted($target)) { return '' }
    return 'windows-disk-cleaner://open?path=' + [System.Uri]::EscapeDataString($target)
  }
  function Get-TensionColor { param([string]$C)
    switch ($C) { 'red' { '#ef5f5f' } 'amber' { '#ef9f27' } 'yellow' { '#dcc46a' } default { '#5dcaa5' } }
  }
  function New-Donut { param([double]$UsedPct, [string]$Color)
    $c = 314.16
    $dash = [math]::Round($c * [math]::Min(100, [math]::Max(0.5, $UsedPct)) / 100, 1)
    $os = '<svg class="donut" viewBox="0 0 120 120">'
    $os += '<circle cx="60" cy="60" r="50" fill="none" stroke="#232730" stroke-width="13"/>'
    $os += ('<circle cx="60" cy="60" r="50" fill="none" stroke="' + $Color + '" stroke-width="13" stroke-linecap="round" stroke-dasharray="' + $dash + ' ' + $c + '" transform="rotate(-90 60 60)"/>')
    $os += ('<text x="60" y="58" text-anchor="middle" class="d-pct">' + [math]::Round($UsedPct, 0) + '%</text>')
    $os += '<text x="60" y="76" text-anchor="middle" class="d-sub">已用</text></svg>'
    return $os
  }
  function New-BarRow { param([string]$Name, [string]$Path, [string]$SizeText, [double]$Pct, [string]$Color, [string]$Category, [string]$Extra, [switch]$OpenParent)
    $fileUrl = Get-ExplorerUrl -Path $Path -OpenParent:$OpenParent
    $os = '<div class="brow"><div class="brow-top">'
    $os += '<span class="dot" style="background:' + $Color + '"></span>'
    $os += '<span class="brow-name">' + (Escape-Html $Name) + '</span>'
    if ($Category) { $os += '<span class="brow-cat">' + (Escape-Html $Category) + '</span>' }
    if ($Extra) { $os += '<span class="brow-extra">' + (Escape-Html $Extra) + '</span>' }
    $os += '<span class="brow-size">' + $SizeText + '</span>'
    if ($fileUrl) { $os += '<a class="open-link" href="' + $fileUrl + '" target="_blank" title="在资源管理器中打开">打开</a>' }
    $os += '</div>'
    $os += ('<div class="track"><i style="width:' + [math]::Max(1.2, [math]::Round($Pct, 1)) + '%;background:' + $Color + '"></i></div>')
    $os += ('<div class="brow-path" title="' + (Escape-Html $Path) + '">' + (Escape-Html $Path) + '</div></div>')
    return $os
  }
  function New-DirectoryCard {
    param([object]$Item, [object[]]$Children, [double]$DriveUsed, [string]$Accent, [bool]$Open)
    $cat = Get-Category -Path $Item.path -Size $Item.size
    $advice = Get-Advice -Category $cat
    $share = if ($DriveUsed -gt 0) { 100 * $Item.size / $DriveUsed } else { 0 }
    $openAttr = if ($Open) { ' open' } else { '' }
    $os = '<details class="space-card"' + $openAttr + '><summary>'
    $os += '<span class="rank-dot" style="background:' + (Get-CatColor $cat) + '"></span>'
    $os += '<span class="space-name">' + (Escape-Html (Get-Leaf $Item.path)) + '</span>'
    $os += '<span class="space-kind">' + (Escape-Html $cat) + '</span>'
    $os += '<span class="space-size">' + (Format-Size $Item.size) + '</span></summary>'
    $os += '<div class="space-share"><i style="width:' + [math]::Max(1.2, [math]::Round($share, 1)) + '%;background:' + $Accent + '"></i></div>'
    $os += '<div class="space-meta"><span>占本盘已用空间 ' + [math]::Round($share, 1) + '%</span><code title="' + (Escape-Html $Item.path) + '">' + (Escape-Html $Item.path) + '</code><a class="open-folder" href="' + (Get-ExplorerUrl $Item.path) + '">在资源管理器中打开</a></div>'
    $os += '<div class="action"><b>建议</b> ' + (Escape-Html $advice.action) + ' <span>' + (Escape-Html $advice.risk) + '</span></div>'
    if ($Children.Count -gt 0) {
      $os += '<div class="children"><div class="children-title">占用较多的子目录</div>'
      $childMax = ($Children | Measure-Object size -Maximum).Maximum
      foreach ($child in $Children) {
        $childPct = if ($childMax -gt 0) { 100 * $child.size / $childMax } else { 0 }
        $childCat = Get-Category -Path $child.path -Size $child.size
        $childAdvice = Get-Advice -Category $childCat
        $os += (New-BarRow -Name (Get-Leaf $child.path) -Path $child.path -SizeText (Format-Size $child.size) -Pct $childPct -Color (Get-CatColor $childCat) -Category $childCat -Extra $childAdvice.action)
      }
      $os += '</div>'
    } else {
      $os += '<div class="children empty">没有达到展示阈值的子目录；可展开其他目录或提高扫描深度。</div>'
    }
    $os += '</details>'
    return $os
  }

  # 每盘一个主题色，标题 chip / 堆叠条高亮全篇一致，便于区分磁盘
  $driveAccents = @{}
  $pal = @('#5dcaa5', '#6aa8f0', '#b48af0', '#f0a55a', '#ef6b6b', '#5ad0c0', '#e8c46b', '#f093ab')
  $di = 0
  foreach ($d in $inventory) { $driveAccents[$d.drive] = $pal[$di % $pal.Count]; $di++ }

  Add-H '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
  Add-H '<meta name="viewport" content="width=device-width,initial-scale=1">'
  Add-H '<title>磁盘空间分析报告</title><style>'
  Add-H ':root{--bg:#0f1115;--card:#171a21;--line:#252932;--fg:#e6e8eb;--mut:#98a1ad;--mono:ui-monospace,Consolas,"Cascadia Mono",monospace}'
  Add-H '*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:24px}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;padding:30px 20px}'
  Add-H '.layout{max-width:1360px;margin:0 auto;display:grid;grid-template-columns:208px minmax(0,1100px);gap:28px}.wrap{min-width:0}h1{font-size:22px;font-weight:500;margin:0 0 6px}h2{font-size:16px;font-weight:500;margin:36px 0 12px;display:flex;align-items:center;gap:10px}h3{font-size:14px;font-weight:500;margin:18px 0 8px;color:var(--mut)}'
  Add-H '.sidebar{position:sticky;top:24px;align-self:start;border:1px solid var(--line);border-radius:12px;background:#14171d;padding:11px;max-height:calc(100vh - 48px);overflow:auto}.nav-title{font-size:12px;color:var(--mut);letter-spacing:.08em;text-transform:uppercase;padding:4px 7px 8px}.nav-link{display:flex;align-items:center;gap:8px;color:#abb4c0;text-decoration:none;border-radius:7px;padding:7px 8px;margin:1px 0;font-size:13px}.nav-link:hover{color:var(--fg);background:#20252e}.nav-dot{width:8px;height:8px;border-radius:50%;background:#697383;flex:none}.nav-section{border-top:1px solid var(--line);margin:8px 0;padding-top:8px}.nav-drive{font-family:var(--mono);font-weight:600;color:#d8dce2}.drive-section{scroll-margin-top:20px}'
  Add-H '@media(max-width:920px){body{padding:16px}.layout{display:block}.sidebar{position:sticky;top:0;z-index:5;max-height:none;margin:-16px -16px 18px;padding:8px 16px;border-radius:0;border-width:0 0 1px;display:flex;gap:4px;overflow-x:auto;white-space:nowrap}.nav-title{display:none}.nav-section{display:contents;border:0;margin:0;padding:0}.nav-link{flex:none;padding:6px 8px}.nav-link:not(.nav-drive){font-size:0}.nav-link:not(.nav-drive) .nav-dot{width:7px;height:7px}.nav-drive{font-size:13px!important}}'
  Add-H '.meta{color:var(--mut);font-size:13px;margin-bottom:20px}'
  Add-H '.chip{display:inline-flex;align-items:center;justify-content:center;min-width:34px;height:26px;padding:0 8px;border-radius:7px;font-family:var(--mono);font-size:14px;font-weight:500;color:#0d1117}'
  Add-H '.dvol{font-weight:500}.dmeta{color:var(--mut);font-size:13px;font-weight:400}'
  Add-H '.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin-bottom:12px}.card-title{color:var(--mut);font-size:13px;margin-bottom:10px}'
  Add-H '.tag{display:inline-block;padding:2px 9px;border-radius:20px;font-size:12px;white-space:nowrap}.t-teal{background:#0f3a30;color:#7fe0bd}.t-amber{background:#3d2c0c;color:#f2c078}.t-blue{background:#12314e;color:#9dc9f2}.t-red{background:#4a1b1b;color:#f19a99}.t-purple{background:#2c2759;color:#c3bdf2}.t-gray{background:#26282d;color:#a9b0ba}.t-yellow{background:#3a3210;color:#dcc46a}'
  Add-H '.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}'
  Add-H '.big{font-size:24px;font-weight:500;font-family:var(--mono);line-height:1.3}.note{color:var(--mut);font-size:13px;margin:2px 0 12px}'
  Add-H '.drives{display:grid;grid-template-columns:repeat(auto-fit,minmax(196px,1fr));gap:12px;margin-bottom:8px}'
  Add-H '.dcard{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;text-align:center;border-top:3px solid var(--acc)}'
  Add-H '.donut{width:104px;height:104px}.d-pct{font-size:23px;fill:var(--fg);font-family:var(--mono)}.d-sub{font-size:10px;fill:var(--mut)}'
  Add-H '.dcard .dname{font-weight:500;margin-top:6px}.dcard .dfree{font-size:21px;font-weight:500;font-family:var(--mono)}.dcard .dsub{color:var(--mut);font-size:12px;margin:2px 0 8px}'
  Add-H '.stacked{display:flex;height:18px;border-radius:9px;overflow:hidden;background:#232730;margin:10px 0 8px}.seg{height:100%;min-width:2px}'
  Add-H '.brow{padding:9px 10px;border-radius:9px;margin-bottom:4px}.brow:hover{background:#1c2029}'
  Add-H '.brow-top{display:flex;align-items:center;gap:8px}.dot{width:9px;height:9px;border-radius:50%;flex:none}'
  Add-H '.brow-name{font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:44%}'
  Add-H '.brow-cat{color:var(--mut);font-size:12px;white-space:nowrap}.brow-extra{color:var(--mut);font-size:12px;white-space:nowrap}'
  Add-H '.brow-size{margin-left:auto;font-family:var(--mono);font-size:13px;white-space:nowrap}'
  Add-H '.open-link,.open-folder{color:#8bdcc0;text-decoration:none;border:1px solid #28604e;border-radius:5px;padding:1px 7px;font-size:11px;white-space:nowrap}.open-link:hover,.open-folder:hover{background:#173d32;color:#c9f5e5}.open-folder{margin-left:auto}'
  Add-H '.track{height:7px;border-radius:4px;background:#232730;overflow:hidden;margin:6px 0 4px}.track>i{display:block;height:100%;border-radius:4px}'
  Add-H '.brow-path{font-family:var(--mono);font-size:11.5px;color:#8b95a2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}'
  Add-H '.tier{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-bottom:12px;border-left:4px solid var(--acc)}'
  Add-H '.tier-head{display:flex;align-items:center;gap:10px;margin-bottom:4px}.tier-title{font-weight:500;font-size:15px}.tier-sum{font-family:var(--mono);font-size:17px;font-weight:500;margin-left:auto}'
  Add-H 'pre{background:#0b0d11;border:1px solid var(--line);border-radius:8px;padding:14px;overflow-x:auto;font-family:var(--mono);font-size:12.5px;line-height:1.65;color:#c8d0da;margin:0}'
  Add-H '.howto{color:#aab3bf;font-size:13px;line-height:1.75;margin-top:10px;padding-top:10px;border-top:1px dashed var(--line)}'
  Add-H '.space-intro{display:flex;justify-content:space-between;align-items:end;gap:16px;margin:34px 0 10px}.space-intro h2{margin:0}.space-intro .note{text-align:right;margin:0}'
  Add-H '.space-card{background:var(--card);border:1px solid var(--line);border-radius:13px;margin:8px 0;overflow:hidden}.space-card[open]{border-color:#3a4350}.space-card summary{display:flex;align-items:center;gap:9px;cursor:pointer;padding:14px 16px;list-style:none}.space-card summary::-webkit-details-marker{display:none}.space-card summary:after{content:"›";color:var(--mut);font-size:22px;line-height:12px;transform:rotate(0deg);margin-left:3px}.space-card[open] summary:after{transform:rotate(90deg)}'
  Add-H '.rank-dot{width:10px;height:10px;border-radius:50%;flex:none}.space-name{font-size:16px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.space-kind{color:var(--mut);font-size:12px}.space-size{font-family:var(--mono);font-size:17px;font-weight:600;margin-left:auto;white-space:nowrap}.space-share{height:6px;background:#252a34;margin:0 16px;overflow:hidden;border-radius:3px}.space-share i{display:block;height:100%;border-radius:3px}.space-meta{display:flex;gap:12px;align-items:center;color:var(--mut);font-size:12px;padding:8px 16px}.space-meta code{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.action{margin:0 16px 13px;padding:9px 11px;background:#101c1a;border:1px solid #1d4b3e;border-radius:7px;color:#bfe4d4;font-size:13px}.action b{color:#75ddb5}.action span{float:right;color:#90a99f}.children{border-top:1px solid var(--line);padding:10px 10px 8px;background:#13161c}.children-title{font-size:12px;color:var(--mut);margin:2px 7px 6px}.children.empty{color:var(--mut);font-size:12px;padding:13px 16px}'
  Add-H '</style></head><body><div class="layout"><aside class="sidebar"><div class="nav-title">报告目录</div>'
  Add-H '<a class="nav-link" href="#overview"><span class="nav-dot"></span>磁盘总览</a><a class="nav-link" href="#reclaim"><span class="nav-dot" style="background:#5dcaa5"></span>可清理空间</a><div class="nav-section">'
  foreach ($d in $inventory) { Add-H ('<a class="nav-link nav-drive" href="#drive-' + $d.drive.TrimEnd(':') + '"><span class="nav-dot" style="background:' + $driveAccents[$d.drive] + '"></span>' + $d.drive + ' 盘</a>') }
  Add-H '</div><div class="nav-section">'
  foreach ($d in @($inventory | Where-Object { $_.free_pct -lt 20 })) { Add-H ('<a class="nav-link" href="#deep-' + $d.drive.TrimEnd(':') + '"><span class="nav-dot" style="background:' + $driveAccents[$d.drive] + '"></span>' + $d.drive + ' 深度大户</a>') }
  Add-H '<a class="nav-link" href="#largest-files"><span class="nav-dot" style="background:#c39bf2"></span>最大文件</a><a class="nav-link" href="#cleanup"><span class="nav-dot" style="background:#ef9f27"></span>清理建议</a><a class="nav-link" href="#decisions"><span class="nav-dot" style="background:#f093ab"></span>需决策项目</a><a class="nav-link" href="#steps"><span class="nav-dot" style="background:#6aa8f0"></span>执行步骤</a></div></aside><div class="wrap">'
  Add-H ('<div id="overview"><h1>磁盘空间分析报告</h1><div class="meta">' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' · 引擎 ' + (Escape-Html $engineNote) + ' · 只读扫描，未删除任何文件</div>')

  # 磁盘卡片：环形图 + 每盘主题色
  Add-H '<div class="drives">'
  foreach ($d in $inventory) {
    $t = Get-Tension $d.free_pct
    $cls = switch ($t.color) { 'red' { 't-red' } 'amber' { 't-amber' } 'yellow' { 't-yellow' } default { 't-teal' } }
    $acc = $driveAccents[$d.drive]
    Add-H ('<div class="dcard" style="--acc:' + $acc + '">')
    Add-H (New-Donut (100 - $d.free_pct) (Get-TensionColor $t.color))
    Add-H ('<div class="dname">' + $d.drive + ' 盘 <span class="tag ' + $cls + '">' + $t.label + '</span></div>')
    Add-H ('<div class="dfree">' + (Format-Size $d.free) + '</div>')
    Add-H ('<div class="dsub">剩余 · 容量 ' + (Format-Size $d.size) + '</div>')
    Add-H '</div>'
  }
  Add-H '</div>'
  Add-H '</div>'

  # 可释放空间汇总
  Add-H '<div id="reclaim" class="grid">'
  foreach ($tier in @('SAFE_DELETE', 'SAFE_IF_CLOSED', 'ADMIN_SAFE')) {
    $items = @($planGroups[$tier])
    if ($items.Count -eq 0) { continue }
    $sum = 0L
    foreach ($i in $items) { $sum += [int64]($i.size_mb * 1MB) }
    $meta = $tierMeta[$tier]
    $cls = switch ($meta.color) { 'teal' { 't-teal' } 'amber' { 't-amber' } default { 't-blue' } }
    $acc = switch ($meta.color) { 'teal' { '#5dcaa5' } 'amber' { '#ef9f27' } default { '#6aa8f0' } }
    Add-H ('<div class="card" style="border-top:3px solid ' + $acc + '"><div class="card-title">' + $meta.title + ' <span class="tag ' + $cls + '">' + $items.Count + ' 项</span></div>')
    Add-H ('<div class="big">' + (Format-Size $sum) + '</div><div class="note">' + $meta.note + '</div></div>')
  }
  Add-H '</div>'

  # 按性质归类：条形排行（替代表格）
  if ($byCategory.Count -gt 0) {
    Add-H '<h2>空间按性质归类</h2><p class="note">同一盘内父子目录分别计入，合计略大于实际占用，用于判断哪类内容占大头。</p>'
    $maxCat = ($byCategory | Measure-Object total -Maximum).Maximum
    foreach ($c in $byCategory) {
      $pct = if ($maxCat -gt 0) { 100 * $c.total / $maxCat } else { 0 }
      $cls = switch ($c.risk) { '低' { 't-teal' } '中' { 't-amber' } '高' { 't-red' } '不建议删除' { 't-purple' } default { 't-gray' } }
      Add-H (New-BarRow -Name $c.category -Path ("共 " + $c.count + " 项 · 建议：" + $c.action) -SizeText (Format-Size $c.total) -Pct $pct -Color (Get-CatColor $c.category) -Category $c.risk)
    }
  }

  # 各盘空间树：顶级目录为主体，展开后直接看到高占用子目录与对应建议。
  foreach ($d in $inventory) {
    $acc = $driveAccents[$d.drive]
    $t = Get-Tension $d.free_pct
    $cls = switch ($t.color) { 'red' { 't-red' } 'amber' { 't-amber' } 'yellow' { 't-yellow' } default { 't-teal' } }
    $prefix = $d.drive + '\'
    $dirs = @($treeRows | Where-Object { $_.is_dir -and $_.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $_.depth -eq 1 } |
      Sort-Object size -Descending | Select-Object -First $Top)
    if ($dirs.Count -eq 0) { continue }

    Add-H ('<section id="drive-' + $d.drive.TrimEnd(':') + '" class="drive-section"><div class="space-intro"><h2><span class="chip" style="background:' + $acc + '">' + $d.drive + '</span><span class="dvol">' + (Escape-Html $d.label) + '</span><span class="tag ' + $cls + '">' + $t.label + '</span></h2><p class="note">容量 ' + (Format-Size $d.size) + ' · 已用 ' + (Format-Size $d.used) + ' · 剩余 ' + $d.free_pct + '%</p></div>')

    # 堆叠条：前 10 个目录占已用空间比例，灰色为其余零散
    $shown = @($dirs | Select-Object -First 10)
    $shownSum = 0L
    foreach ($x in $shown) { $shownSum += $x.size }
    $remain = $d.used - $shownSum
    if ($remain -lt 0) { $remain = 0 }
    Add-H ('<div class="card"><div class="card-title">空间分布 · 已用 ' + (Format-Size $d.used) + '</div><div class="stacked">')
    foreach ($x in $shown) {
      $pct = if ($d.used -gt 0) { 100 * $x.size / $d.used } else { 0 }
      $col = Get-CatColor (Get-Category -Path $x.path -Size $x.size)
      Add-H ('<div class="seg" style="width:' + [math]::Max(0.35, [math]::Round($pct, 2)) + '%;background:' + $col + '" title="' + (Escape-Html $x.path) + ' · ' + (Format-Size $x.size) + '"></div>')
    }
    if ($remain -gt 0) {
      $rpct = if ($d.used -gt 0) { 100 * $remain / $d.used } else { 0 }
      Add-H ('<div class="seg" style="width:' + [math]::Round($rpct, 2) + '%;background:#3a3f4a" title="其余零散文件 · ' + (Format-Size $remain) + '"></div>')
    }
    Add-H '</div><div class="note">颜色对应内容性质；灰色为其余零散文件。下面按占用从大到小排列，可展开查看每个目录的子目录和处理建议。</div></div>'

    $allDeep = @($treeRows | Where-Object { $_.is_dir -and $_.depth -eq 2 -and $_.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $rank = 0
    foreach ($x in $dirs) {
      $rank++
      $children = @($allDeep | Where-Object { (Split-Path -Path $_.path -Parent).TrimEnd('\') -eq $x.path.TrimEnd('\') } | Sort-Object size -Descending | Select-Object -First 6)
      Add-H (New-DirectoryCard -Item $x -Children $children -DriveUsed $d.used -Accent $acc -Open ($rank -le 4))
    }
    Add-H '</section>'
  }

  # 最大文件
  # 细查模式中，列出定向下钻得到的真实大户。
  foreach ($d in @($inventory | Where-Object { $_.free_pct -lt 20 })) {
    $prefix = $d.drive + '\'
    $deepHotspots = @($drillRows | Where-Object {
      $_.is_dir -and $_.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $_.size -ge 1GB
    } | Sort-Object size -Descending | Select-Object -First 24)
    if ($deepHotspots.Count -eq 0) { continue }

    Add-H ('<h2 id="deep-' + $d.drive.TrimEnd(':') + '"><span class="chip" style="background:' + $driveAccents[$d.drive] + '">' + $d.drive + '</span>' + $d.drive + ' 盘深度大户</h2>')
    Add-H '<p class="note">来自对最大二级目录的定向下钻。这里列出超过 1 GB 的实际子目录；父子目录可能同时出现，体积不应相加。</p>'
    Add-H '<div class="card deep-hotspots">'
    $maxDeepHotspot = ($deepHotspots | Measure-Object size -Maximum).Maximum
    foreach ($x in $deepHotspots) {
      $pct = if ($maxDeepHotspot -gt 0) { 100 * $x.size / $maxDeepHotspot } else { 0 }
      $cat = Get-Category -Path $x.path -Size $x.size
      $adv = Get-Advice -Category $cat
      $relative = $x.path.Substring($prefix.Length)
      Add-H (New-BarRow -Name $relative -Path $x.path -SizeText (Format-Size $x.size) -Pct $pct -Color (Get-CatColor $cat) -Category $cat -Extra ('第 ' + $x.depth + ' 层 · ' + $adv.action))
    }
    Add-H '</div>'
  }

  $largestFiles = @($fileRows | Where-Object { $_ -and $null -ne $_.PSObject.Properties['size'] } |
    Sort-Object size -Descending | Select-Object -First 12)
  if ($largestFiles.Count -gt 0) {
    Add-H '<h2 id="largest-files">最大的单个文件</h2>'
    $maxFile = ($largestFiles | Measure-Object size -Maximum).Maximum
    foreach ($f in $largestFiles) {
      $cat = Get-Category -Path $f.path -Size $f.size
      $pct = if ($maxFile -gt 0) { 100 * $f.size / $maxFile } else { 0 }
      Add-H (New-BarRow -Name (Get-Leaf $f.path) -Path $f.path -SizeText (Format-Size $f.size) -Pct $pct -Color (Get-CatColor $cat) -Category $cat -Extra $f.drive -OpenParent)
    }
  }

  # 清理建议：分档卡片
  Add-H '<h2 id="cleanup">清理建议</h2>'
  $idx = 0
  foreach ($tier in $order) {
    $items = @($planGroups[$tier])
    if ($items.Count -eq 0) { continue }
    $idx++
    $meta = $tierMeta[$tier]
    $sum = 0L
    foreach ($i in $items) { $sum += [int64]($i.size_mb * 1MB) }
    $acc = switch ($meta.color) { 'teal' { '#5dcaa5' } 'amber' { '#ef9f27' } 'blue' { '#6aa8f0' } 'red' { '#ef5f5f' } 'purple' { '#b48af0' } default { '#8a97a8' } }
    $cls = switch ($meta.color) { 'teal' { 't-teal' } 'amber' { 't-amber' } 'blue' { 't-blue' } 'red' { 't-red' } 'purple' { 't-purple' } default { 't-gray' } }
    Add-H ('<div class="tier" style="--acc:' + $acc + '"><div class="tier-head"><span class="tier-title">' + $idx + '. ' + $meta.title + '</span><span class="tag ' + $cls + '">' + $items.Count + ' 项</span><span class="tier-sum">' + (Format-Size $sum) + '</span></div>')
    Add-H ('<div class="note">' + $meta.note + '</div>')
    $tierMax = 0L
    foreach ($i in $items) { if ([int64]($i.size_mb * 1MB) -gt $tierMax) { $tierMax = [int64]($i.size_mb * 1MB) } }
    foreach ($i in @($items | Select-Object -First 12)) {
      $b = [int64]($i.size_mb * 1MB)
      $pct = if ($tierMax -gt 0) { 100 * $b / $tierMax } else { 0 }
      Add-H (New-BarRow -Name $i.owner -Path $i.path -SizeText (Format-Size $b) -Pct $pct -Color $acc -Category $i.category)
    }
    if ($items.Count -gt 12) { Add-H ('<div class="note">其余 ' + ($items.Count - 12) + ' 项未列出。</div>') }
    if ($tierAction.ContainsKey($tier)) {
      $guideLines = @($tierAction[$tier] -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
      Add-H '<div class="howto"><b>怎么清</b><br>'
      foreach ($g in $guideLines) { Add-H ((Escape-Html $g) + '<br>') }
      Add-H '</div>'
    }
    Add-H '</div>'
  }

  # 需决策
  if ($manual.Count -gt 0) {
    Add-H '<h2 id="decisions">需要你决策的大额项目</h2><p class="note">体量大但不该直接删除，工具已自动排除在清理范围外。</p>'
    $maxM = ($manual | Measure-Object size -Maximum).Maximum
    foreach ($m in $manual) {
      $pct = if ($maxM -gt 0) { 100 * $m.size / $maxM } else { 0 }
      Add-H (New-BarRow -Name (Get-Leaf $m.path) -Path $m.path -SizeText (Format-Size $m.size) -Pct $pct -Color (Get-CatColor $m.category) -Category $m.category -Extra ($m.action + ' · 重建成本 ' + $m.rebuild))
    }
    Add-H '<div class="howto"><b>处理原则</b><br>模型权重、引擎资产、项目本体：迁移到其他盘，用目录联接保持原路径可用<br>Git 仓库：用 <code>git gc --aggressive</code> 压缩，不要手删 .git/objects<br>虚拟磁盘：先 wsl --shutdown 或停 Docker 再压缩<br>回收站：确认没有需要恢复的文件后再清空</div>'
  }

  # 命令
  Add-H '<h2 id="steps">执行步骤</h2>'
  Add-H '<pre># 1. 预演，不删除任何文件'
  if ($PlanPath) { Add-H ('clean_space.ps1 -PlanPath "' + $PlanPath + '" -DryRun') } else { Add-H 'scan_space.ps1 -Drives C: -Mode Fast' }
  Add-H ''
  Add-H '# 2. 只清低风险项（无需关软件）'
  if ($PlanPath) { Add-H ('clean_space.ps1 -PlanPath "' + $PlanPath + '" -Only SAFE_DELETE') }
  Add-H ''
  Add-H '# 3. 关掉 Chrome / Edge / IDE 后，再清这一批'
  if ($PlanPath) { Add-H ('clean_space.ps1 -PlanPath "' + $PlanPath + '" -Only SAFE_IF_CLOSED') }
  Add-H '</pre>'
  Add-H '<p class="note">保留回收站内容，避免误删不可恢复；确需清空时加 <code>-ClearRecycleBin</code>。</p>'
  Add-H '</div></div></body></html>'

  [System.IO.File]::WriteAllText($htmlPath, $html.ToString(), $utf8Bom)
}

Write-Output ('REPORT_MD: ' + $mdPath)
if (-not $NoHtml) { Write-Output ('REPORT_HTML: ' + $htmlPath) }
Write-Output ('ENGINE: ' + $engineNote)
Write-Output ('PLAN: ' + $PlanPath)
