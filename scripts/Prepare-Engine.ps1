#requires -Version 7.0
# Downloads the pinned llama.cpp release (Vulkan build), verifies SHA-256 and lays out engine/cpu and engine/vulkan.
# CUDA is not bundled: the app installs it on demand into the user profile (see CudaEngineInstaller).
param([string]$CacheDir = '')
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$engine = Join-Path $repo 'engine'
$downloads = Join-Path $repo 'build/downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$tag = 'b12121'
$name = "llama-$tag-bin-win-vulkan-x64.zip"
$hash = '73111d348dcbfa86050611c28b8bef523c849d80a6e5529e25b67f1b2055e918'
$archive = Join-Path $downloads $name
if (!(Test-Path -LiteralPath $archive) -and $CacheDir -and (Test-Path -LiteralPath (Join-Path $CacheDir $name))) {
    Copy-Item -LiteralPath (Join-Path $CacheDir $name) -Destination $archive
}
if (!(Test-Path -LiteralPath $archive)) {
    curl.exe -fLsS --retry 3 -o "$archive.part" "https://github.com/ggml-org/llama.cpp/releases/download/$tag/$name"
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $name" }
    Move-Item -LiteralPath "$archive.part" -Destination $archive -Force
}
if ((Get-FileHash -LiteralPath $archive).Hash -ne $hash) { throw "Unexpected engine archive hash: $name" }
$staging = Join-Path $repo 'build/engine-staging'
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$staging/extract", "$staging/vulkan", "$staging/cpu" | Out-Null
& "$env:SystemRoot/System32/tar.exe" -xf $archive -C "$staging/extract"
if ($LASTEXITCODE -ne 0) { throw 'Extraction failed' }
Get-ChildItem -LiteralPath "$staging/extract" -Recurse -File | Where-Object {
    $_.Name -match '^(ggml(?:-base|-cpu-[^.]+|-vulkan)?|libomp|llama|llama-common|llama-server-impl|mtmd)\.dll$|^llama-server\.exe$|^LICENSE'
} | Copy-Item -Destination "$staging/vulkan" -Force
# The CPU engine is the same build without the Vulkan backend DLL (never touches the GPU driver).
Get-ChildItem -LiteralPath "$staging/vulkan" -File | Where-Object { $_.Name -ne 'ggml-vulkan.dll' } | Copy-Item -Destination "$staging/cpu"
curl.exe -fLsS --retry 3 -o "$staging/LICENSE-llama.cpp" "https://raw.githubusercontent.com/ggml-org/llama.cpp/$tag/LICENSE"
if ($LASTEXITCODE -ne 0) { throw 'Could not download llama.cpp license' }
foreach ($b in 'cpu', 'vulkan') { Copy-Item "$staging/LICENSE-llama.cpp" "$staging/$b/LICENSE-llama.cpp" }
if (Test-Path -LiteralPath $engine) { Remove-Item -LiteralPath $engine -Recurse -Force }
New-Item -ItemType Directory -Force -Path $engine | Out-Null
foreach ($b in 'cpu', 'vulkan') { Copy-Item -LiteralPath "$staging/$b" -Destination $engine -Recurse }
Write-Output "Prepared CPU / Vulkan engines ($tag) in $engine"
