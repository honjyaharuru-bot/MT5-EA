$ErrorActionPreference = "Stop"
$me  = "$env:MT5_INSTALL\metaeditor64.exe"
$src = "$env:MT5_DATA\MQL5\Experts\FVG_EA.mq5"
$log = "$PWD\compile.log"
if (Test-Path $log) { Remove-Item $log -Force }
Start-Process -FilePath $me -ArgumentList "/compile:`"$src`"","/log:`"$log`"" -Wait -NoNewWindow
if (Test-Path $log) {
  $text = Get-Content $log -Encoding Unicode -Raw
  Write-Host $text
  if ($text -match '(\d+)\s+error') {
    if ([int]$Matches[1] -gt 0) { throw "Compile failed: $($Matches[1]) error(s)" }
  }
}
$ex5 = "$env:MT5_DATA\MQL5\Experts\FVG_EA.ex5"
if (-not (Test-Path $ex5)) { throw "EX5 not produced" }
Write-Host "Compile OK"
