# Build and publish Notchcode as an NSIS installer on GitHub Releases.
# The Windows counterpart of release-mac.sh (no signing/notarization step —
# the installer ships unsigned, so SmartScreen shows "More info > Run anyway").
#
# One-time prerequisites:
#   1. Rust toolchain (rustup) + `npm install` in windows/app
#   2. gh auth login
#
# Usage: .\scripts\release-windows.ps1 <version>   e.g. .\scripts\release-windows.ps1 1.0.0
param(
    [Parameter(Mandatory = $true)][string]$Version
)
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AppDir = Join-Path $RepoRoot "windows\app"
$Repo = "billxby/notchcode"
$Installer = Join-Path $AppDir "src-tauri\target\release\bundle\nsis\Notchcode_${Version}_x64-setup.exe"

# Stamp the release version without editing tauri.conf.json — the Windows
# analog of the Mac script's MARKETING_VERSION override. (WriteAllText keeps
# the file BOM-free so the Tauri CLI can parse it.)
$Override = Join-Path $env:TEMP "notchcode-release-config.json"
[IO.File]::WriteAllText($Override, "{`"version`": `"$Version`"}")

Write-Host "==> Building NSIS installer (release, v$Version)"
Push-Location $AppDir
try {
    npx tauri build --config $Override
    if ($LASTEXITCODE -ne 0) { throw "tauri build failed (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
}

if (-not (Test-Path $Installer)) { throw "expected installer not found: $Installer" }
Write-Host "==> Built $Installer"

Write-Host "==> Publishing GitHub release v$Version"
# gh prints to stderr when the release doesn't exist; relax the error
# preference so the probe's redirected stderr can't terminate the script.
$ErrorActionPreference = "Continue"
gh release view "v$Version" --repo $Repo *> $null
$exists = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = "Stop"

if ($exists) {
    gh release upload "v$Version" $Installer --clobber --repo $Repo
}
else {
    gh release create "v$Version" $Installer `
        --repo $Repo `
        --title "Notchcode v$Version" `
        --generate-notes
}
if ($LASTEXITCODE -ne 0) { throw "gh release failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "Done! Release: https://github.com/$Repo/releases/tag/v$Version"
