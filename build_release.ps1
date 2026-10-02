# Builds the release APKs with the keys from .env.
#
#   .\build_release.ps1
#
# Output: build\app\outputs\flutter-apk\app-arm64-v8a-release.apk (and the
# other ABIs). Keys are read from .env, which is git-ignored.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Test-Path '.env')) {
    Write-Host 'No .env file. Copy .env.example to .env and add your key.' -ForegroundColor Red
    exit 1
}

$key = (Get-Content '.env' | Where-Object { $_ -match '^\s*GEMINI_API_KEY\s*=' }) -replace '^\s*GEMINI_API_KEY\s*=\s*', ''
if ([string]::IsNullOrWhiteSpace($key)) {
    # Still builds: read-aloud just uses the phone's own voice.
    Write-Host 'Warning: GEMINI_API_KEY is empty in .env - Gemini voice will be unavailable in this build.' -ForegroundColor Yellow
}

flutter build apk --split-per-abi --release --dart-define-from-file=.env
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host 'Install this one on phones: build\app\outputs\flutter-apk\app-arm64-v8a-release.apk' -ForegroundColor Green
