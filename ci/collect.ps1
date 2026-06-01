$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path results | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$json = "$env:MT5_DATA\MQL5\Files\fvg_result.json"
if (Test-Path $json) {
  Copy-Item $json "results\result-$stamp.json" -Force
  Copy-Item $json "results\latest.json" -Force
  Write-Host "JSON取得OK"
} else { Write-Host "JSONなし" }
$report = "$env:TEMP\report.htm"
if (Test-Path $report) {
  Copy-Item $report "results\report-$stamp.htm" -Force
  Write-Host "HTMLレポート取得OK"
}
