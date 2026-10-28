param(
  [switch]$Force
)

# 安装/更新 gdu（磁盘用量扫描引擎，report.ps1 依赖它）。
# 依次尝试 winget -> chocolatey -> scoop，都不可用时回退为直接下载 GitHub Release。

$ErrorActionPreference = 'Stop'

function Test-GduAvailable {
  $cmd = Get-Command gdu -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\gdu.exe'
  if (Test-Path -LiteralPath $link) { return $link }
  return $null
}

$existing = Test-GduAvailable
if ($existing -and -not $Force) {
  "gdu 已安装：$existing"
  & $existing --version 2>$null | Select-Object -First 1
  return
}

$installedVia = ''

# 1) winget（Windows 10 1809+ 一般自带）
$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget -and -not $installedVia) {
  try {
    "正在通过 winget 安装 gdu ..."
    & winget install --id dundee.gdu -e --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $installedVia = 'winget' }
  } catch { }
}

# 2) chocolatey
if (-not $installedVia) {
  $choco = Get-Command choco -ErrorAction SilentlyContinue
  if ($choco) {
    try {
      "正在通过 chocolatey 安装 gdu ..."
      & choco install gdu -y --no-progress 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { $installedVia = 'chocolatey' }
    } catch { }
  }
}

# 3) scoop
if (-not $installedVia) {
  $scoop = Get-Command scoop -ErrorAction SilentlyContinue
  if ($scoop) {
    try {
      "正在通过 scoop 安装 gdu ..."
      & scoop install main/gdu 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { $installedVia = 'scoop' }
    } catch { }
  }
}

# 4) 直接下载 GitHub Release（zip 内是单个 exe）
if (-not $installedVia) {
  try {
    "包管理器不可用，直接从 GitHub Release 下载 gdu ..."
    $dest = Join-Path $env:LOCALAPPDATA 'gdu'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $zip = Join-Path $dest 'gdu.zip'
    $url = 'https://github.com/dundee/gdu/releases/latest/download/gdu_windows_amd64.exe.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    # 把目录加进当前用户 PATH
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$dest*") {
      [Environment]::SetEnvironmentVariable('Path', "$userPath;$dest", 'User')
    }
    $installedVia = "direct download ($dest)"
  } catch {
    Write-Warning "gdu 自动安装失败：$($_.Exception.Message)"
  }
}

if ($installedVia) {
  "gdu 安装完成（via $installedVia）。"
  if ($installedVia -like 'winget*') {
    '注意：winget 安装后需要重开终端才会在 PATH 中生效。'
  }
  $found = Test-GduAvailable
  if ($found) { "gdu 路径：$found" } else { '当前会话找不到 gdu，重开终端后即可使用。' }
} else {
  Write-Warning 'gdu 未能自动安装。可手动从 https://github.com/dundee/gdu/releases 下载 gdu_windows_amd64.exe.zip 并放入 PATH。'
}
