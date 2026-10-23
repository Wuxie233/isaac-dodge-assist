$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /warn:4 /out:"$PSScriptRoot\IsaacDodge.exe" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "$PSScriptRoot\IsaacDodge.cs"
if ($LASTEXITCODE -ne 0) { throw 'C# compilation failed' }
Get-FileHash "$PSScriptRoot\IsaacDodge.exe" -Algorithm SHA256
