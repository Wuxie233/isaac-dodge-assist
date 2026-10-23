param([string]$GameDirectory)
$ErrorActionPreference = 'Stop'
if (-not $GameDirectory) {
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Select The Binding of Isaac Rebirth folder (contains isaac-ng.exe)'
    if ($picker.ShowDialog() -ne 'OK') { exit 1 }
    $GameDirectory = $picker.SelectedPath
    $picker.Dispose()
}
if (-not (Test-Path -LiteralPath (Join-Path $GameDirectory 'isaac-ng.exe') -PathType Leaf)) {
    throw 'Selected folder does not contain isaac-ng.exe.'
}
if (Get-Process isaac-ng -ErrorAction SilentlyContinue) { throw 'Close Isaac before installing.' }
$target = Join-Path $env:LOCALAPPDATA 'IsaacDodgeAssist'
$modTarget = Join-Path $GameDirectory 'mods\isaac_dodge_assist'
New-Item -ItemType Directory -Path $target,$modTarget -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'helper\IsaacDodge.exe') -Destination $target -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $target 'README.txt') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'COVERAGE.md') -Destination $target -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall.ps1') -Destination $target -Force
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'mod\isaac_dodge_assist') -Filter '*.lua' | Copy-Item -Destination $modTarget -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mod\isaac_dodge_assist\metadata.xml') -Destination $modTarget -Force
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Isaac Dodge Assist.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $target 'IsaacDodge.exe'
$shortcut.WorkingDirectory = $target
$shortcut.Description = 'Isaac emergency dodge - keyboard WASD'
$shortcut.Save()
@{gameDirectory=$GameDirectory; modDirectory=$modTarget; shortcut=$shortcutPath} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'installation.json') -Encoding UTF8
Write-Output "Installed mod: $modTarget"
Write-Output "Helper: $target\IsaacDodge.exe"
Write-Output "Desktop shortcut: $shortcutPath"
