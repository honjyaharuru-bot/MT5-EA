# deploy.ps1 - one-command EA deploy from Google Drive to GitHub (triggers CI)
# Usage on VPS:  cd C:\MT5-EA ; .\ci\deploy.ps1
$ErrorActionPreference = "Stop"

$repo   = "C:\MT5-EA"
$branch = "claude/fvg-ea-mt5-DNeln"

# Auto-detect Drive subfolder (Japanese name safe), then MT5-Results
$driveRoot  = (Get-ChildItem "G:\" | Select-Object -First 1).FullName
$resultsDir = Join-Path $driveRoot "MT5-Results"

# Pick the NEWEST .mq5 on Drive (so versioned filenames just work)
$src = Get-ChildItem $resultsDir -Filter *.mq5 |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $src) { Write-Host "No .mq5 found in $resultsDir"; exit 1 }
Write-Host "Source : $($src.Name)  (modified $($src.LastWriteTime))"

Copy-Item $src.FullName (Join-Path $repo "src\fvg_ea.mq5") -Force
Write-Host "Copied -> src\fvg_ea.mq5"

Push-Location $repo
git add -A
if (git status --porcelain) {
    git commit -m "deploy $($src.BaseName)"
    git pull --rebase origin $branch
    git push origin $branch
    Write-Host "Pushed. CI triggered on $branch."
} else {
    Write-Host "No changes vs committed source. Nothing to push."
}
Pop-Location
