# MyPLaMo SnapTrans: build the distribution ZIP
#   pwsh -File packaging\package.ps1                 (version from Directory.Build.props)
#   pwsh -File packaging\package.ps1 -Version 1.2.0
#
# Output (dist\):
#   MyPLaMo-SnapTrans-<version>-win-x64.zip          top folder MyPLaMo-SnapTrans\ contains:
#       MyPLaMo-SnapTrans.exe        small launcher (Native AOT, src\SnapTrans.Launcher). Starts app\MyPLaMo.SnapTrans.exe and exits
#       README.txt                   end-user guide (Japanese, then English)
#       LICENSE.txt                  this project's license (repository LICENSE)
#       THIRD-PARTY-NOTICES.txt      licenses of everything bundled under app\
#       app\                         the WinUI 3 app, self-contained .NET / Windows App SDK runtime, engine\ (llama.cpp)
#   MyPLaMo-SnapTrans-<version>-win-x64.zip.sha256   "<sha256>  <file name>" (sha256sum -c compatible)
#
# Release / win-x64 / self-contained / unpackaged (no MSIX). No single-file publish, no trimming, no ReadyToRun.
# Models (*.gguf) are never bundled: users download them in Settings from PFN's Hugging Face repositories.
# PDBs are not shipped (DebugType=None + a final sweep). The script fails if the ZIP would contain a model,
# a PDB, or a string that identifies the build machine (user name, profile path, repository path, git e-mail).
#
# Needs: .NET 10 SDK, PowerShell 7, and Visual Studio "Desktop development with C++" (MSVC linker for the
# Native AOT launcher; its VC++ redistributable files are also copied next to the llama.cpp / Tesseract DLLs).
[CmdletBinding()]
param(
    [string]$Version = '',
    # Folder that already holds llama-b12121-bin-win-vulkan-x64.zip (skips the download in Prepare-Engine.ps1).
    [string]$EngineCache = '',
    # Do not copy msvcp140.dll / vcruntime140*.dll next to the native DLLs (the user then needs the VC++ redistributable).
    [switch]$NoVcRuntime
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root      = Split-Path -Parent $PSScriptRoot
$appProj   = Join-Path $root 'src\SnapTrans.App\SnapTrans.App.csproj'
$launcherProj = Join-Path $root 'src\SnapTrans.Launcher\SnapTrans.Launcher.csproj'
$dist      = Join-Path $root 'dist'
$stage     = Join-Path $dist 'stage'
$topName   = 'MyPLaMo-SnapTrans'
$topDir    = Join-Path $stage $topName
$appDir    = Join-Path $topDir 'app'
$appExe    = 'MyPLaMo.SnapTrans.exe'
$launcherExe = 'MyPLaMo-SnapTrans.exe'

# --- version
if (-not $Version) {
    [xml]$props = Get-Content -LiteralPath (Join-Path $root 'Directory.Build.props') -Encoding UTF8
    $Version = @($props.Project.PropertyGroup | ForEach-Object { $_['Version'] } | Where-Object { $_ } | ForEach-Object { $_.InnerText })[0]
    if (-not $Version) { throw '<Version> not found in Directory.Build.props' }
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must look like 1.2.3: $Version" }
$name    = "$topName-$Version-win-x64"
$zipPath = Join-Path $dist "$name.zip"
$commit  = (& git -C $root rev-parse --short HEAD 2>$null)
$dirty   = (& git -C $root status --porcelain 2>$null)
Write-Host "== MyPLaMo SnapTrans $Version (commit $commit$(if ($dirty) { ', with uncommitted changes' }))"

# --- clean
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
foreach ($f in @($zipPath, "$zipPath.sha256")) { if (Test-Path $f) { Remove-Item $f -Force } }

# --- llama.cpp engine (engine\cpu, engine\vulkan; pinned release + SHA-256 in Prepare-Engine.ps1)
if (!(Test-Path (Join-Path $root 'engine\vulkan\llama-server.exe')) -or !(Test-Path (Join-Path $root 'engine\cpu\llama-server.exe'))) {
    & (Join-Path $root 'scripts\Prepare-Engine.ps1') -CacheDir $EngineCache
}

# --- app (WinUI 3, self-contained). ContinuousIntegrationBuild maps source paths to /_/ (no local paths in binaries).
Write-Host '== dotnet publish app (Release, win-x64, self-contained)'
& dotnet publish $appProj -c Release -r win-x64 --self-contained true -o $appDir -nologo -v minimal `
    -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false -p:GenerateDocumentationFile=false `
    -p:ContinuousIntegrationBuild=true "-p:Version=$Version"
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }

# --- launcher (Native AOT). ILCompiler finds MSVC through vswhere.exe on PATH.
Write-Host '== dotnet publish launcher (Native AOT)'
$vsInstaller = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
if (Test-Path $vsInstaller) { $env:PATH = "$env:PATH;$vsInstaller" }
$launcherOut = Join-Path $stage 'launcher'
& dotnet publish $launcherProj -c Release -r win-x64 -o $launcherOut -nologo -v minimal `
    -p:ContinuousIntegrationBuild=true "-p:Version=$Version"
if ($LASTEXITCODE -ne 0) { throw "launcher build failed ($LASTEXITCODE)" }
Copy-Item (Join-Path $launcherOut $launcherExe) (Join-Path $topDir $launcherExe)
Remove-Item $launcherOut -Recurse -Force

# --- remove what users do not need: debug symbols, docs, 32-bit Tesseract (the app is x64 only)
$junk = @(Get-ChildItem $topDir -Recurse -File -Include *.pdb, *.xml, *.dbg, *.ilk, *.lib, *.exp, *.map)
$junk | Remove-Item -Force
if (Test-Path (Join-Path $appDir 'x86')) { Remove-Item (Join-Path $appDir 'x86') -Recurse -Force }
Write-Host ("== removed {0} debug/dev files and app\x86" -f $junk.Count)

# --- VC++ runtime next to the native DLLs that import it (llama.cpp engine, Tesseract/Leptonica)
$vcFiles = 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'
$vcDir = $null
if (-not $NoVcRuntime) {
    $vswhere = Join-Path $vsInstaller 'vswhere.exe'
    $vsPath = if (Test-Path $vswhere) { & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath } else { $null }
    if (-not $vsPath) { throw 'Visual Studio with the C++ workload was not found (needed for the VC++ runtime files). Use -NoVcRuntime to skip.' }
    $vcDir = Get-ChildItem (Join-Path $vsPath 'VC\Redist\MSVC') -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $vcDir) { throw 'VC++ redistributable folder (VC\Redist\MSVC\<ver>\x64\Microsoft.VC*.CRT) not found.' }
    foreach ($target in @($appDir, (Join-Path $appDir 'engine\cpu'), (Join-Path $appDir 'engine\vulkan'))) {
        foreach ($f in $vcFiles) { Copy-Item (Join-Path $vcDir.FullName $f) (Join-Path $target $f) -Force }
    }
    Write-Host "== VC++ runtime: $($vcDir.Parent.Parent.Name) ($($vcDir.Name))"
}

# --- README / LICENSE / THIRD-PARTY-NOTICES (CRLF; README with BOM so Notepad on older Windows shows Japanese)
function Write-Text([string]$path, [string]$text, [bool]$bom) {
    [IO.File]::WriteAllText($path, ($text -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($bom)))
}
$readme = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'README.txt') -Raw -Encoding UTF8).Replace('{VERSION}', $Version)
Write-Text (Join-Path $topDir 'README.txt') $readme $true

$licenseSrc = Join-Path $root 'LICENSE'
if (Test-Path $licenseSrc) {
    Write-Text (Join-Path $topDir 'LICENSE.txt') (Get-Content -LiteralPath $licenseSrc -Raw -Encoding UTF8) $false
} else {
    Write-Warning 'LICENSE is missing in the repository: LICENSE.txt is NOT in the ZIP. Add a LICENSE before publishing.'
}

# Third-party notices: hand-written overview + the license texts of what is actually in app\.
$nugetRoot = (& dotnet nuget locals global-packages --list) -replace '^global-packages:\s*', ''
$deps = Get-Content (Join-Path $appDir 'MyPLaMo.SnapTrans.deps.json') -Raw | ConvertFrom-Json
$libs = $deps.libraries.PSObject.Properties
function PackageDir([string]$id) {
    $p = $libs | Where-Object { $_.Name -like "$id/*" } | Select-Object -First 1
    if (-not $p) { throw "package $id not found in deps.json" }
    Join-Path $nugetRoot $p.Value.path
}
$runtimeLib = $libs | Where-Object { $_.Name -like 'runtimepack.Microsoft.NETCore.App.Runtime.win-x64/*' } | Select-Object -First 1
if (-not $runtimeLib) { throw 'runtime pack not found in deps.json' }
$runtimePack = Get-Item (Join-Path $nugetRoot ('microsoft.netcore.app.runtime.win-x64\' + $runtimeLib.Name.Split('/')[1]))
$waSdk = Join-Path $nugetRoot ('microsoft.windowsappsdk\' + (($libs | Where-Object { $_.Name -like 'Microsoft.WindowsAppSDK/*' } | Select-Object -First 1).Name.Split('/')[1]))
$winUi = PackageDir 'Microsoft.WindowsAppSDK.WinUI'
$webView = PackageDir 'Microsoft.Web.WebView2'
$mlDir = Join-Path $nugetRoot ('microsoft.windowsappsdk.ml\' + (Split-Path $waSdk -Leaf))
$winMlDir = PackageDir 'Microsoft.Windows.AI.MachineLearning'
$lic = Join-Path $PSScriptRoot 'licenses'
$sections = [ordered]@{
    'llama.cpp b12121 (engine\cpu, engine\vulkan: llama-server.exe, llama*.dll, ggml*.dll, mtmd.dll) - MIT License' = Join-Path $root 'engine\vulkan\LICENSE-llama.cpp'
    'BoringSSL 0.20261020.0 (statically linked in engine\*\llama-common.dll, llama-server-impl.dll) - Apache License 2.0' = Join-Path $lic 'LICENSE-boringssl.txt'
    'fiat-crypto (bundled in BoringSSL 0.20261020.0) - Apache License 2.0' = Join-Path $lic 'fiat-crypto.txt'
    'llamafile sgemm (ggml-cpu-*.dll, Mozilla Foundation) - MIT License' = Join-Path $lic 'llamafile-sgemm.txt'
    'common/base64.hpp (llama-common.dll) - The Unlicense' = Join-Path $lic 'base64-hpp.txt'
    'cpp-httplib v0.64.0 (vendored in llama.cpp b12121) - MIT License' = Join-Path $lic 'cpp-httplib.txt'
    'nlohmann/json v3.12.0 (vendored in llama.cpp b12121) - MIT License' = Join-Path $lic 'nlohmann-json.txt'
    'miniaudio (vendored in llama.cpp b12121, mtmd.dll) - Public Domain (Unlicense) / MIT-0' = Join-Path $lic 'miniaudio.txt'
    'stb_image (vendored in llama.cpp b12121, mtmd.dll) - MIT License / Public Domain' = Join-Path $lic 'stb.txt'
    'sheredom/subprocess.h (vendored in llama.cpp b12121) - The Unlicense' = Join-Path $lic 'sheredom-subprocess.txt'
    'xxHash (vendored in llama.cpp b12121, mtmd.dll) - BSD 2-Clause License' = Join-Path $lic 'xxhash.txt'
    'rotate-bits.h (vendored in llama.cpp b12121, mtmd.dll) - MIT License' = Join-Path $lic 'rotate-bits.txt'
    'sha256.c (vendored in llama.cpp b12121, mtmd.dll) - Public Domain' = Join-Path $lic 'sha256-c.txt'
    'clibs/sha1 (vendored in llama.cpp b12121, mtmd.dll) - Public Domain' = Join-Path $lic 'clibs-sha1.txt'
    'llama.cpp b12121 embedded WebUI (llama-server-impl.dll, disabled via --no-webui) - frontend third-party notices' = Join-Path $lic 'llama-ui-notices.txt'
    'LLVM OpenMP runtime (engine\*\libomp.dll) - Apache License 2.0 with LLVM Exceptions' = Join-Path $root 'engine\vulkan\LICENSE-LLVM-OpenMP'
    ".NET runtime $($runtimePack.Name) (System.*.dll, Microsoft.*.dll of .NET, coreclr.dll, hostfxr.dll ...) - MIT License" = Join-Path $runtimePack.FullName 'LICENSE.TXT'
    ".NET runtime $($runtimePack.Name) - third-party notices" = Join-Path $runtimePack.FullName 'THIRD-PARTY-NOTICES.TXT'
    "Windows App SDK $(Split-Path $waSdk -Leaf) (Microsoft.UI.*, Microsoft.Windows.*, WinUI, DWriteCore, WinRT.Runtime ...) - Microsoft Software License Terms" = Join-Path $waSdk 'license.txt'
    "Windows App SDK $(Split-Path $waSdk -Leaf) - third-party notices" = Join-Path $waSdk 'NOTICE.txt'
    "Windows App SDK WinUI $(Split-Path $winUi -Leaf) - third-party notices" = Join-Path $winUi 'NOTICE.txt'
    "Windows App SDK ML $(Split-Path $mlDir -Leaf) - Microsoft Software License Terms" = Join-Path $mlDir 'license.txt'
    "Microsoft Windows AI MachineLearning $(Split-Path $winMlDir -Leaf) (Microsoft.ML.OnnxRuntime.dll, onnxruntime.dll, DirectML.dll ...) - Microsoft Software License Terms" = Join-Path $winMlDir 'license.txt'
    "Microsoft Windows AI MachineLearning $(Split-Path $winMlDir -Leaf) - third-party notices" = Join-Path $winMlDir 'ThirdPartyNotices.txt'
    "Microsoft Edge WebView2 SDK $(Split-Path $webView -Leaf) (Microsoft.Web.WebView2.Core.dll) - license" = Join-Path $webView 'LICENSE.txt'
    'Tesseract .NET wrapper 5.2.0 by Charles Weld (Tesseract.dll) and Tesseract OCR 5 (x64\tesseract50.dll) - Apache License 2.0' = Join-Path $lic 'Apache-2.0.txt'
    'Leptonica 1.82.0 (x64\leptonica-1.82.0.dll) - BSD 2-Clause style' = Join-Path $lic 'leptonica.txt'
    'libtiff 4.4.0 (statically linked in leptonica-1.82.0.dll)' = Join-Path $lic 'libtiff.txt'
    'libjpeg-turbo 2.1.4 (statically linked in leptonica-1.82.0.dll) - IJG / BSD-3-Clause / zlib' = Join-Path $lic 'libjpeg-turbo.txt'
    'libpng 1.6.37 (statically linked in leptonica-1.82.0.dll) - PNG Reference Library License v2' = Join-Path $lic 'libpng.txt'
    'GIFLIB (statically linked in leptonica-1.82.0.dll) - MIT License' = Join-Path $lic 'giflib.txt'
    'zlib 1.2.13 (statically linked in leptonica-1.82.0.dll) - zlib License' = Join-Path $lic 'zlib.txt'
}
$sb = [Text.StringBuilder]::new()
[void]$sb.Append((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.header.txt') -Raw -Encoding UTF8).Replace('{VERSION}', $Version))
if ($vcDir) {
    [void]$sb.AppendLine().AppendLine("Microsoft Visual C++ runtime $($vcDir.Parent.Parent.Name) (msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll in app\, app\engine\cpu, app\engine\vulkan):")
    [void]$sb.AppendLine('  Distributable Code of Microsoft Visual Studio, redistributed under the Visual Studio license terms.')
}
foreach ($k in $sections.Keys) {
    $file = $sections[$k]
    if (-not (Test-Path -LiteralPath $file)) { throw "license text missing: $file" }
    [void]$sb.AppendLine().AppendLine(('=' * 78)).AppendLine($k).AppendLine(('=' * 78)).AppendLine()
    [void]$sb.AppendLine((Get-Content -LiteralPath $file -Raw -Encoding UTF8).TrimEnd())
}
Write-Text (Join-Path $topDir 'THIRD-PARTY-NOTICES.txt') $sb.ToString() $true

foreach ($req in @((Join-Path $topDir $launcherExe), (Join-Path $appDir $appExe), (Join-Path $appDir 'engine\vulkan\llama-server.exe'), (Join-Path $appDir 'engine\cpu\llama-server.exe'))) {
    if (-not (Test-Path $req)) { throw "missing: $req" }
}

# --- pre-publish checks: no models, no symbols, nothing that identifies this machine or its owner
Write-Host '== checks'
$bad = @(Get-ChildItem $topDir -Recurse -File -Include *.gguf, *.bin, *.safetensors, *.pdb, *.log, settings.json, verify-cache.json, *.traineddata)
if ($bad) { throw "unexpected files in the package:`n$($bad.FullName -join "`n")" }
$needles = [Collections.Generic.List[string]]::new()
# The bare user name is matched as part of a path only: a short name also occurs by chance in binary data.
foreach ($n in @("Users\$env:USERNAME", "Users/$env:USERNAME", $env:USERPROFILE, $root, (Split-Path $root -Parent), (& git -C $root config user.email 2>$null), (& git -C $root config user.name 2>$null))) {
    if ($n -and $n.Length -ge 4 -and $n -notin @('User', 'Admin', 'runneradmin')) { $needles.Add($n) }
}
$hits = @()
foreach ($f in Get-ChildItem $topDir -Recurse -File) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $ascii = [Text.Encoding]::Latin1.GetString($bytes)
    $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
    foreach ($n in $needles) {
        if ($ascii.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $utf16.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $hits += "$($f.FullName.Substring($topDir.Length + 1)): contains '$n'"
        }
    }
}
if ($hits) { throw "the package contains machine/owner specific strings:`n$($hits -join "`n")" }
Write-Host ("== checks passed ({0} files, {1} patterns)" -f (Get-ChildItem $topDir -Recurse -File).Count, $needles.Count)

# --- ZIP ("/" separators, top folder MyPLaMo-SnapTrans/, fixed order)
Write-Host '== zip'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $baseLen = $stage.TrimEnd('\').Length + 1
    Get-ChildItem $topDir -Recurse -File | Sort-Object FullName | ForEach-Object {
        $entry = $_.FullName.Substring($baseLen).Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $zip.Dispose() }

# --- SHA256
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$zipPath.sha256", "$hash  $name.zip`n", (New-Object Text.UTF8Encoding($false)))
Remove-Item $stage -Recurse -Force

$size = (Get-Item $zipPath).Length
Write-Host ''
Write-Host ("Done: {0}  ({1:N0} bytes)" -f $zipPath, $size)
Write-Host "SHA256: $hash"
Write-Host "Commit: $commit$(if ($dirty) { ' (+ uncommitted changes)' })"
