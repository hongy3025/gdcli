#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"

if (-not $env:GODOT_BIN) {
    throw "GODOT_BIN is required for M1 E2E smoke"
}

$RepoRoot = Resolve-Path "$PSScriptRoot/.."
$Fixture = Join-Path $RepoRoot "tests\fixture_project"
$GdcliBin = Join-Path $RepoRoot "target\debug\gdcli.exe"
$GdapiDll = Join-Path $RepoRoot "target\debug\gdapi.dll"
$Meta = Join-Path $Fixture ".godot\gdapi.json"
$AddonBin = Join-Path $Fixture "addons\gdapi\bin\windows"

function Invoke-GdcliJson($ArgsList) {
    $output = & $GdcliBin --json @ArgsList
    if ($LASTEXITCODE -ne 0) {
        throw "gdcli failed: $($ArgsList -join ' ')`n$output"
    }
    return $output | ConvertFrom-Json
}

function Assert-HasRoute($Routes, $Name) {
    if ($Routes -notcontains $Name) {
        throw "missing route: $Name"
    }
}

cargo build --workspace
& $GdcliBin install --project $Fixture --force
if (-not (Test-Path $AddonBin)) { New-Item -ItemType Directory -Force -Path $AddonBin | Out-Null }
Copy-Item $GdapiDll $AddonBin -Force

$Godot = $null
try {
    if (Test-Path $Meta) { Remove-Item -Force $Meta }
    $Godot = Start-Process -FilePath $env:GODOT_BIN -ArgumentList "--editor", "--headless", "--path", $Fixture -PassThru

    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        if (Test-Path $Meta) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "gdapi.json never appeared" }

    $ping = Invoke-GdcliJson @("exec", "ping", "--project", $Fixture)
    if (-not $ping.ok) { throw "ping did not return ok:true" }

    $routes = Invoke-GdcliJson @("exec", "routes", "--project", $Fixture)
    Assert-HasRoute $routes.routes "editor/scene/create"
    Assert-HasRoute $routes.routes "scene/create"
    Assert-HasRoute $routes.routes "shared/godot/version"
    Assert-HasRoute $routes.routes "godot/version"
    if (-not $routes.aliases."scene/create") { throw "scene/create alias metadata missing" }

    $commands = Invoke-GdcliJson @("exec", "commands", "--project", $Fixture)
    $sceneCreate = $commands.commands | Where-Object { $_.path -eq "editor/scene/create" } | Select-Object -First 1
    if (-not $sceneCreate) { throw "commands missing editor/scene/create" }
    if ($sceneCreate.canonical_path -ne "editor/scene/create") { throw "canonical_path mismatch" }

    $help = Invoke-GdcliJson @("exec", "command-help", "scene/create", "--project", $Fixture)
    if ($help.doc.canonical_path -ne "editor/scene/create") { throw "legacy command-help did not resolve canonical path" }

    $safePath = Invoke-GdcliJson @("exec", "project/health/path_check", "--project", $Fixture, "--data", '{"path":"scenes/test.tscn","mode":"read"}')
    if ($safePath.path -ne "res://scenes/test.tscn") { throw "path_check did not normalize project-relative path" }

    & $GdcliBin --json exec project/health/path_check --project $Fixture --data '{"path":"../outside.txt","mode":"read"}' | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "path traversal was accepted" }

    & $GdcliBin --json exec project/audit/clear --project $Fixture --data '{}' | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "audit clear without force was accepted" }

    $cleared = Invoke-GdcliJson @("exec", "project/audit/clear", "--project", $Fixture, "--data", '{"force":true}')
    if (-not $cleared.ok) { throw "audit clear force failed" }

    Write-Host "PASS: M1 E2E smoke" -ForegroundColor Green
} finally {
    if ($Godot) { Stop-Process -Id $Godot.Id -Force -ErrorAction SilentlyContinue }
}
