$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'IsaacDodgeAssist'
$record = Join-Path $target 'installation.json'
if (-not (Test-Path -LiteralPath $record)) { throw 'Installation record not found.' }
if (Get-Process IsaacDodge,IsaacDodgeNativeHost,isaac-ng -ErrorAction SilentlyContinue) { throw 'Close Isaac and both input helpers before uninstalling.' }
$info = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
# Only delete known package files; preserve any user additions.
foreach ($name in @('terrain_snapshot.lua','motion_prediction.lua','threat_field.lua','dodge_planner.lua','diagnostics.lua', 'main.lua','laser_hazards.lua','area_index.lua','escape_space.lua','tnt_hazards.lua','metadata.xml')) {
    $path = Join-Path $info.modDirectory $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
if ((Test-Path -LiteralPath $info.modDirectory) -and -not (Get-ChildItem -LiteralPath $info.modDirectory -Force)) {
    Remove-Item -LiteralPath $info.modDirectory
}
if (Test-Path -LiteralPath $info.shortcut) { Remove-Item -LiteralPath $info.shortcut -Force }
foreach ($name in @('IsaacDodge.exe','README.txt','COVERAGE.md','installation.json','Uninstall.ps1')) {
    $path = Join-Path $target $name
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
if (-not (Get-ChildItem -LiteralPath $target -Force)) { Remove-Item -LiteralPath $target }
Write-Output 'Isaac Dodge Assist removed. Other mods and game files were not changed.'
