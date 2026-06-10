$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path results | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

$mqRoot = Join-Path $env:APPDATA "MetaQuotes"
$searchDirs = @(
  (Join-Path $mqRoot "Tester"),
  (Join-Path $mqRoot "Terminal\Common\Files")
)
if ($env:MT5_DATA) { $searchDirs += (Join-Path $env:MT5_DATA "MQL5\Files") }

$cutoff = (Get-Date).AddMinutes(-60)
$found = $searchDirs | Where-Object { Test-Path $_ } |
  ForEach-Object { Get-ChildItem -Path $_ -Recurse -Filter "fvg_result.json" -ErrorAction SilentlyContinue } |
  Where-Object { $_.LastWriteTime -ge $cutoff } |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($found) {
  Copy-Item $found.FullName "results\result-$stamp.json" -Force
  Copy-Item $found.FullName "results\latest.json" -Force
  if ($env:SYMBOL) {
    try { $j = Get-Content $found.FullName -Raw | ConvertFrom-Json } catch { $j = $null }
    if ($j -and $j.symbol -eq $env:SYMBOL) {
      Copy-Item $found.FullName "results\result_$($env:SYMBOL).json" -Force
    } else {
      Write-Host "WARN: freshest JSON symbol '$($j.symbol)' != expected '$env:SYMBOL' - no per-symbol file written"
    }
  }
  Write-Host "JSON found: $($found.FullName)"
  Write-Host "Modified: $($found.LastWriteTime)"
} else {
  Write-Host "JSON not found (fresh) in Tester/Common/Data"
}

$repDirs = @($env:MT5_INSTALL, $env:MT5_DATA, $env:TEMP) | Where-Object { $_ -and (Test-Path $_) }
$rep = $repDirs |
  ForEach-Object { Get-ChildItem -Path $_ -Filter "*report*.htm" -ErrorAction SilentlyContinue } |
  Where-Object { $_.LastWriteTime -ge $cutoff } |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($rep) {
  Copy-Item $rep.FullName "results\report-$stamp.htm" -Force
  Write-Host "Report found: $($rep.FullName)"
}
