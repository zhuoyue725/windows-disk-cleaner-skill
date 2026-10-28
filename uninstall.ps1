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
    Remove-Item -LiteralPath $path -Recurse -Force
    $removed += [pscustomobject]@{ target = $name; path = $path; status = 'removed' }
  } else {
    $removed += [pscustomobject]@{ target = $name; path = $path; status = 'not found' }
  }
}

$removed | Format-Table -AutoSize
