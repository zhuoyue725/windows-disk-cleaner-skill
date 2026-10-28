param(
  [ValidateSet('codex','claude','workbuddy','all')]
  [string]$Target = 'all',

  # 同时安装扫描引擎 gdu（推荐，报告功能需要它；不装则只能跑基础清理计划）
  [switch]$InstallGdu,

  [string]$SkillSource = (Join-Path $PSScriptRoot 'skills\windows-disk-cleaner')
)

$ErrorActionPreference = 'Stop'

if (!(Test-Path -LiteralPath (Join-Path $SkillSource 'SKILL.md'))) {
  throw "Skill source not found: $SkillSource"
}

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
  if (Test-Path -LiteralPath $dest) {
    Get-ChildItem -LiteralPath $SkillSource -Force | Copy-Item -Destination $dest -Recurse -Force
  } else {
    Copy-Item -LiteralPath $SkillSource -Destination $root -Recurse -Force
  }
  $installed += [pscustomobject]@{ target = $name; path = $dest }
}

'Installed windows-disk-cleaner skill:'
$installed | Format-Table -AutoSize

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
