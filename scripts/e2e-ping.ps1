#!/usr/bin/env pwsh
# Windows 版端到端验证。
$ErrorActionPreference = "Stop"

$GodotBin = $env:GODOT_BIN
if (-not $GodotBin) { $GodotBin = "godot" }

$RepoRoot = Resolve-Path "$PSScriptRoot/.."
$Fixture = Join-Path $RepoRoot "tests\fixture_project"
$AddonDir = Join-Path $Fixture "addons\gdapi"
$GdcliBin = Join-Path $RepoRoot "target\debug\gdcli.exe"

# 1. 复制 addon
if (Test-Path $AddonDir) { Remove-Item -Recurse -Force $AddonDir }
New-Item -ItemType Directory -Path $AddonDir | Out-Null
Copy-Item -Recurse "$RepoRoot\gdapi\addon\*" $AddonDir

New-Item -ItemType Directory -Force -Path "$AddonDir\bin\windows" | Out-Null
$DllSrc = "$RepoRoot\target\debug\gdapi.dll"
if (Test-Path $DllSrc) {
    Copy-Item $DllSrc "$AddonDir\bin\windows\"
} else {
    Write-Warning "gdapi.dll not built. Run: cargo build -p gdapi"
    exit 1
}

# 2. 启动 Godot
Write-Host "Starting Godot editor..."
try {
    $Godot = Start-Process -FilePath $GodotBin `
        -ArgumentList "--editor", "--headless", "--path", $Fixture `
        -PassThru

    $Meta = Join-Path $Fixture ".godot\gdapi.json"
    $Ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Path $Meta) {
            $Ready = $true
            Write-Host "gdapi meta appeared"
            Get-Content $Meta
            break
        }
        Start-Sleep -Seconds 1
    }

    if (-not $Ready) {
        Write-Host "ERROR: gdapi.json never appeared" -ForegroundColor Red
        exit 1
    }

    Write-Host "Calling: gdcli exec ping --project $Fixture"
    $Output = & $GdcliBin exec ping --project $Fixture
    Write-Host "Response: $Output"

    $ExitCode = 0
    if ($Output -match '"ok":true') {
        Write-Host "PASS: e2e ping succeeded" -ForegroundColor Green
    } else {
        Write-Host "FAIL: unexpected response" -ForegroundColor Red
        $ExitCode = 1
    }
} finally {
    if ($Godot) {
        Stop-Process -Id $Godot.Id -Force -ErrorAction SilentlyContinue
    }
}
exit $ExitCode
