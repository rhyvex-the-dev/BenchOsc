$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$RustManifest = Join-Path $RootDir "rust_core\Cargo.toml"
$RustDll = Join-Path $RootDir "rust_core\target\release\open_bench_sim.dll"
$AppDir = Join-Path $RootDir "app"
$ReleaseDir = Join-Path $AppDir "build\windows\x64\runner\Release"
$DistDir = Join-Path $RootDir "dist"
$ZipPath = Join-Path $DistDir "open-bench-windows-x64.zip"

cargo build --release --manifest-path $RustManifest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (-not (Test-Path $RustDll)) {
    throw "Missing Rust DLL: $RustDll"
}

Push-Location $AppDir
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    flutter gen-l10n
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

$BundledDll = Join-Path $ReleaseDir "open_bench_sim.dll"
if (-not (Test-Path $BundledDll)) {
    throw "open_bench_sim.dll was not bundled into $ReleaseDir"
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
if (Test-Path $ZipPath) {
    Remove-Item -Force $ZipPath
}
Compress-Archive -Path "$ReleaseDir\*" -DestinationPath $ZipPath
Write-Host "Packaged $ZipPath"
