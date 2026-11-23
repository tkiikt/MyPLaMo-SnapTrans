#requires -Version 7.0
<#
.SYNOPSIS
  Builds the SnapTrans icons from the SVG sources in assets/icon (design "F": navy + blue bubble + white corners).

.DESCRIPTION
  Renderer: resvg 0.49.0 (official GitHub release, Windows x64), pinned by version and SHA-256 and downloaded on
  first use into build/tools/resvg-0.49.0 (git-ignored). No fonts are involved (shapes only), so the same SVG input
  always produces the same PNG bytes, and the ICO container is written deterministically below.

  Outputs (src/SnapTrans.App/Assets):
    SnapTrans.ico        app icon: 16/20/24/32 px from app-small.svg, 48/64/128/256 px from app.svg
    SnapTrans-48.png     small app image for the settings title bar (from app-small.svg, crisp at 18 DIP up to 200 %)
    TrayLight.ico        tray icon for a light taskbar (16..48 px, tray-light.svg)
    TrayDark.ico         tray icon for a dark taskbar  (16..48 px, tray-dark.svg)

.EXAMPLE
  pwsh -File scripts/Make-Icon.ps1            # download resvg if needed, render, write icons
  pwsh -File scripts/Make-Icon.ps1 -Check     # re-render into a temp folder and verify the committed icons are identical
#>
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$svgDir = Join-Path $repo 'assets/icon'
$outDir = if ($Check) { Join-Path ([IO.Path]::GetTempPath()) ("snaptrans-icon-check-" + [Guid]::NewGuid().ToString('N')) } else { Join-Path $repo 'src/SnapTrans.App/Assets' }

# ---- Pinned renderer -------------------------------------------------------------------------------------------
$resvgVersion = '0.49.0'
$resvgZipSha256 = '38af9631b37e61118a32a5ef31e6be6af083eda63b4c17ffc4fdc63e449277df'
$toolDir = Join-Path $repo "build/tools/resvg-$resvgVersion"
$resvg = Join-Path $toolDir 'resvg.exe'
if (!(Test-Path -LiteralPath $resvg)) {
    New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
    $zip = Join-Path $toolDir 'resvg-win-x86_64.zip'
    curl.exe -fLsS --retry 3 -o $zip "https://github.com/linebender/resvg/releases/download/v$resvgVersion/resvg-win-x86_64.zip"
    if ($LASTEXITCODE -ne 0) { throw 'Could not download resvg' }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $resvgZipSha256) { Remove-Item $zip; throw 'Unexpected resvg archive hash' }
    & "$env:SystemRoot/System32/tar.exe" -xf $zip -C $toolDir
    if ($LASTEXITCODE -ne 0) { throw 'Could not extract resvg' }
}
$version = (& $resvg --version).Trim()
if ($version -ne $resvgVersion) { throw "resvg $resvgVersion required, found $version" }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$work = Join-Path $outDir '.render'
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Render([string]$svg, [int]$size) {
    $png = Join-Path $work ("{0}-{1}.png" -f [IO.Path]::GetFileNameWithoutExtension($svg), $size)
    & $resvg -w $size -h $size (Join-Path $svgDir $svg) $png
    if ($LASTEXITCODE -ne 0) { throw "resvg failed for $svg @ $size" }
    return ,([IO.File]::ReadAllBytes($png))  # comma: keep the byte[] intact (no pipeline unrolling)
}

# ICO with PNG-compressed entries (supported by Windows Vista and later), entries in ascending size order.
function Write-Ico([string]$path, [object[]]$entries) {
    $ms = [IO.MemoryStream]::new(); $w = [IO.BinaryWriter]::new($ms)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$entries.Count)
    $offset = 6 + 16 * $entries.Count
    foreach ($e in $entries) {
        $s = $e.Size
        $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256)); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]([byte[]]$e.Png).Length); $w.Write([uint32]$offset)
        $offset += ([byte[]]$e.Png).Length
    }
    foreach ($e in $entries) { $w.Write([byte[]]$e.Png) }
    $w.Flush()
    [IO.File]::WriteAllBytes($path, $ms.ToArray())
}

$app = @()
foreach ($s in 16, 20, 24, 32) { $app += @{ Size = $s; Png = (Render 'app-small.svg' $s) } }
foreach ($s in 48, 64, 128, 256) { $app += @{ Size = $s; Png = (Render 'app.svg' $s) } }
Write-Ico (Join-Path $outDir 'SnapTrans.ico') $app
[IO.File]::WriteAllBytes((Join-Path $outDir 'SnapTrans-48.png'), (Render 'app-small.svg' 48))
foreach ($theme in 'light', 'dark') {
    $tray = @()
    foreach ($s in 16, 20, 24, 32, 40, 48) { $tray += @{ Size = $s; Png = (Render "tray-$theme.svg" $s) } }
    Write-Ico (Join-Path $outDir ("Tray{0}.ico" -f (Get-Culture).TextInfo.ToTitleCase($theme))) $tray
}
Remove-Item -LiteralPath $work -Recurse -Force

if ($Check) {
    $committed = Join-Path $repo 'src/SnapTrans.App/Assets'
    $diff = foreach ($f in 'SnapTrans.ico', 'SnapTrans-48.png', 'TrayLight.ico', 'TrayDark.ico') {
        if ((Get-FileHash (Join-Path $outDir $f)).Hash -ne (Get-FileHash (Join-Path $committed $f)).Hash) { $f }
    }
    Remove-Item -LiteralPath $outDir -Recurse -Force
    if ($diff) { throw "Icons differ from a fresh render: $($diff -join ', ')" }
    Write-Output "Icons match a fresh render (resvg $resvgVersion)."
} else {
    Get-ChildItem $outDir -File | Where-Object Name -match '^(SnapTrans|Tray)' | ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName).Hash.Substring(0, 16), $_.Name }
}
