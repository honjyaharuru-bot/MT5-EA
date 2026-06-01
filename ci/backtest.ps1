$ErrorActionPreference = "Stop"
$ini = "$env:MT5_INSTALL\fvg_test.ini"
$rep = "$env:MT5_INSTALL\report"
@"
[Tester]
Expert=FVG_EA.ex5
Symbol=$env:SYMBOL
Period=$env:PERIOD
Model=$env:MODEL
Optimization=0
FromDate=$env:FROM
ToDate=$env:TO
ForwardMode=0
Deposit=$env:DEPOSIT
Currency=USD
Leverage=1:100
Report=$rep
ReplaceReport=1
ShutdownTerminal=1
"@ | Set-Content -Path $ini -Encoding Ascii
Write-Host "バックテスト開始"
Start-Process -FilePath "$env:MT5_INSTALL\terminal64.exe" -ArgumentList "/config:`"$ini`"" -Wait
Write-Host "バックテスト終了"
