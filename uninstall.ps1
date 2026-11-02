param(
  [ValidateSet('codex','claude','workbuddy','all')]
  [string]$Target = 'all'
)

$ErrorActionPreference = 'Stop'

$targets = [ordered]@{
  codex = Join-Path $env:USERPROFILE '.codex\skills\windows-disk-cleaner'
  claude = Join-Path $env:USERPROFILE '.claude\skills\windows-disk-cleaner'
  workbuddy = Join-Path $env:USERPROFILE '.workbuddy\skills\windows-disk-cleaner'
}

$selected = if ($Target -eq 'all') { @('codex','claude','workbuddy') } else { @($Target) }
$removed = @()

foreach ($name in $selected) {
  $path = $targets[$name]
  if (Test-Path -LiteralPath $path) {
    $item = Get-Item -LiteralPath $path -Force
    # 目录链接只移除链接本身，绝不递归删除其指向的 Skill 源目录。
    if ($item.LinkType -eq 'Junction' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      Remove-Item -LiteralPath $path -Force
    } else {
      Remove-Item -LiteralPath $path -Recurse -Force
    }
    $removed += [pscustomobject]@{ target = $name; path = $path; status = 'removed' }
  } else {
    $removed += [pscustomobject]@{ target = $name; path = $path; status = 'not found' }
  }
}

$removed | Format-Table -AutoSize
