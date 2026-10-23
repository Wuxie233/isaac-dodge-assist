$ErrorActionPreference = 'Stop'
& "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x86 /main:NativeHost /r:System.Windows.Forms.dll /r:System.Drawing.dll "/out:$PSScriptRoot\IsaacDodgeNativeHost.exe" "$PSScriptRoot\NativeHost.cs" "$PSScriptRoot\PacketClock.cs"
if ($LASTEXITCODE -ne 0) { throw 'Native host compilation failed' }
