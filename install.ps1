param(
  [ValidateSet('codex','claude','workbuddy','all')]
  [string]$Target = 'all',

  # 同时安装扫描引擎 gdu（推荐，报告功能需要它；不装则只能跑基础清理计划）
  [switch]$InstallGdu,

  # Copy：独立拷贝，适合普通下载安装；Link：目录链接，适合本机开发时让多个 agent 共用同一份源文件。
  [ValidateSet('Copy','Link')]
  [string]$Mode = 'Copy',

  [string]$SkillSource = (Join-Path $PSScriptRoot 'skills\windows-disk-cleaner')
)

$ErrorActionPreference = 'Stop'

if (!(Test-Path -LiteralPath (Join-Path $SkillSource 'SKILL.md'))) {
  throw "Skill source not found: $SkillSource"
}
$SkillSource = (Resolve-Path -LiteralPath $SkillSource).Path

$targets = [ordered]@{
  codex    = Join-Path $env:USERPROFILE '.codex\skills'
  claude   = Join-Path $env:USERPROFILE '.claude\skills'
  workbuddy = Join-Path $env:USERPROFILE '.workbuddy\skills'
}

$selected = if ($Target -eq 'all') { @('codex','claude','workbuddy') } else { @($Target) }
$installed = @()

foreach ($name in $selected) {
  $root = $targets[$name]
  $dest = Join-Path $root 'windows-disk-cleaner'
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  if ($Mode -eq 'Link') {
    $existing = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    $alreadyLinked = $existing -and $existing.LinkType -eq 'Junction' -and @($existing.Target) -contains $SkillSource
    if (-not $alreadyLinked) {
      $backup = $null
      if ($existing) {
        $backup = $dest + '.backup-' + (Get-Date -Format 'yyyyMMddHHmmss')
        Move-Item -LiteralPath $dest -Destination $backup -ErrorAction Stop
      }
      try {
        New-Item -ItemType Junction -Path $dest -Target $SkillSource -ErrorAction Stop | Out-Null
        if (!(Test-Path -LiteralPath (Join-Path $dest 'SKILL.md'))) { throw 'Junction verification failed.' }
        if ($backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
      } catch {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
        if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $dest -ErrorAction SilentlyContinue }
        throw
      }
    }
  } else {
    if (Test-Path -LiteralPath $dest) {
      Get-ChildItem -LiteralPath $SkillSource -Force | Copy-Item -Destination $dest -Recurse -Force
    } else {
      Copy-Item -LiteralPath $SkillSource -Destination $root -Recurse -Force
    }
  }
  $installed += [pscustomobject]@{ target = $name; mode = $Mode; path = $dest }
}

# 注册本机 URL 协议，让 HTML 报告中的“打开”按钮启动 Windows 资源管理器，
# 而不是由浏览器显示 file:/// 目录索引。注册在当前用户下，无需管理员权限。
$protocolSkillPath = $installed[0].path
$protocolHandler = Join-Path $protocolSkillPath 'scripts\open_in_explorer.ps1'
if (Test-Path -LiteralPath $protocolHandler) {
  $protocol = 'windows-disk-cleaner'
  $protocolKey = "HKCU:\Software\Classes\$protocol"
  New-Item -Path "$protocolKey\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path $protocolKey -Name '(default)' -Value 'URL: Windows Disk Cleaner Explorer Link'
  New-ItemProperty -Path $protocolKey -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
  $psExe = (Get-Command powershell.exe -ErrorAction Stop).Source
  $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" "%1"' -f $psExe, $protocolHandler
  Set-ItemProperty -Path "$protocolKey\shell\open\command" -Name '(default)' -Value $command
}

'Installed windows-disk-cleaner skill:'
$installed | Format-Table -AutoSize
if (Test-Path -LiteralPath $protocolHandler) {
  '已注册报告目录打开协议：点击 HTML 报告中的“打开”会启动 Windows 资源管理器。'
}

# 说明：本仓库所有 .ps1 均保存为 UTF-8 with BOM。
# Windows PowerShell 5.1 对无 BOM 文件按 ANSI 解析，中文字符串会损坏，
# 如果后续自行修改脚本，请保持带 BOM 保存。

if ($InstallGdu) {
  & (Join-Path $PSScriptRoot 'setup-gdu.ps1')
} else {
  ''
  '提示：report.ps1 依赖 gdu 做全盘空间统计。建议运行：'
  '  powershell -ExecutionPolicy Bypass -File .\setup-gdu.ps1'
  '不安装 gdu 也能使用扫描与清理，但分析报告会缺少目录体积排行与大文件列表。'
}
