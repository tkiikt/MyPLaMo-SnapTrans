#requires -Version 7.0
# Builds the portable app: release\MyPLaMo-SnapTrans\MyPLaMo.SnapTrans.exe (+ ZIP).
# WinUI 3 unpackaged, self-contained: no MSIX / .NET / Windows App SDK install needed on the target PC.
# Models are NOT bundled; users download them in Settings from Hugging Face (pfnet).
param([string]$EngineCache = '')
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (!(Test-Path engine/vulkan/llama-server.exe) -or !(Test-Path engine/cpu/llama-server.exe)) {
        ./scripts/Prepare-Engine.ps1 -CacheDir $EngineCache
    }
    $out = Join-Path $PSScriptRoot 'release/MyPLaMo-SnapTrans'
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
    dotnet publish src/SnapTrans.App/SnapTrans.App.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:DebugType=None -o $out
    if ($LASTEXITCODE -ne 0) { throw 'publish failed' }
    Copy-Item README.md $out
    $zip = Join-Path $PSScriptRoot 'release/MyPLaMo-SnapTrans-win-x64.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    Compress-Archive -Path $out -DestinationPath $zip
    Write-Output "Done: $out\MyPLaMo.SnapTrans.exe"
    Write-Output "ZIP : $zip"
} finally { Pop-Location }
