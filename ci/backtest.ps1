$ErrorActionPreference = "Stop"

# Close existing MT5 to avoid instance conflict
Write-Host "Closing existing MT5..."
$mt5 = Get-Process terminal64 -ErrorAction SilentlyContinue
if ($mt5) {
    $mt5.CloseMainWindow() | Out-Null
    $mt5.WaitForExit(15000)
    if (-not $mt5.HasExited) {
        $mt5 | Stop-Process -Force
        Start-Sleep -Seconds 3
    }
    Write-Host "MT5 closed"
} else {
    Write-Host "MT5 not running"
}

$ini = "$env:TEMP\fvg_test.ini"
$rep = "$env:TEMP\report"

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

Write-Host "Backtest start"
Start-Process -FilePath "$env:MT5_INSTALL\terminal64.exe" -ArgumentList "/config:`"$ini`"" -Wait
Write-Host "Backtest done"

Write-Host "Restarting MT5..."
Start-Process "$env:MT5_INSTALL\terminal64.exe"
Write-Host "MT5 restarted"
