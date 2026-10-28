param(
  [Parameter(Mandatory = $true)]
  [string]$Uri
)

# 仅处理本 Skill 生成的本机目录链接，避免把任意命令参数交给 explorer.exe。
$ErrorActionPreference = 'Stop'

try { $parsed = [System.Uri]$Uri } catch { exit 1 }
if ($parsed.Scheme -ne 'windows-disk-cleaner' -or $parsed.Host -ne 'open') { exit 1 }

$path = $null
foreach ($pair in $parsed.Query.TrimStart('?').Split('&')) {
  $parts = $pair.Split('=', 2)
  if ($parts.Count -eq 2 -and $parts[0] -eq 'path') {
    $path = [System.Uri]::UnescapeDataString($parts[1])
    break
  }
}

if ([string]::IsNullOrWhiteSpace($path) -or -not [System.IO.Path]::IsPathRooted($path)) { exit 1 }
if (-not (Test-Path -LiteralPath $path -PathType Container)) { exit 1 }

Start-Process -FilePath explorer.exe -ArgumentList @($path)
