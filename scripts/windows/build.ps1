<#
.SYNOPSIS
  Builds the GitComet desktop app for Windows and optionally packages a
  portable ZIP, mirroring the CI release build
  (.github/workflows/build-release-artifacts.yml).

.DESCRIPTION
  Checks the Windows prerequisites (Rust toolchain, MSVC linker, Windows SDK),
  then runs:

    cargo build -p gitcomet --release --locked --features ui-gpui,gix --bin gitcomet

  The repository's .cargo/config.toml already points the linker at
  scripts/windows/msvc-linker.cmd, so no shell setup is required beyond having
  Visual Studio Build Tools / Community installed.

.PARAMETER Configuration
  Build profile: Release (default), Debug, or ReleaseWithDebug.

.PARAMETER Arch
  Architecture to build for: host (default), x64, or arm64. Cross-compiling
  requires the matching rustup target, e.g. `rustup target add
  aarch64-pc-windows-msvc`.

.PARAMETER Features
  Cargo feature list for the gitcomet crate. Defaults to "ui-gpui,gix" (the
  full GUI app used by the release pipeline).

.PARAMETER Package
  Also create the portable ZIP under dist/ (gitcomet-v<version>-windows-<arch>
  -portable.zip) with the binary, README, LICENSE, and NOTICE.

.PARAMETER SkipLocked
  Do not pass --locked to cargo (use this if Cargo.lock is out of date).

.EXAMPLE
  .\scripts\windows\build.ps1

  Build the release binary at target\release\gitcomet.exe.

.EXAMPLE
  .\scripts\windows\build.ps1 -Package -Arch arm64

  Cross-compile for ARM64 and emit the portable ZIP.
#>
[CmdletBinding()]
param(
  [ValidateSet("Release", "Debug", "ReleaseWithDebug")]
  [string]$Configuration = "Release",

  [ValidateSet("host", "x64", "arm64")]
  [string]$Arch = "host",

  [string]$Features = "ui-gpui,gix",

  [switch]$Package,

  [switch]$SkipLocked
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ── Helpers ────────────────────────────────────────────────────────────────
function Write-Step {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Assert-CommandOnPath {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Hint
  )
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "'$Name' was not found on PATH.`n$Hint"
  }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$targetDir = Join-Path $repoRoot "target"

# ── Architecture ───────────────────────────────────────────────────────────
$cargoTarget = $null
$archLabel = $Arch
$linkerArch = $Arch

if ($Arch -eq "host") {
  $isArm64 = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
  $archLabel = if ($isArm64) { "arm64" } else { "x64" }
}

if ($archLabel -eq "arm64") {
  $cargoTarget = "aarch64-pc-windows-msvc"
  $linkerArch = "arm64"
} elseif ($archLabel -eq "x64") {
  $cargoTarget = "x86_64-pc-windows-msvc"
  $linkerArch = "x64"
}

# ── Prerequisite checks ────────────────────────────────────────────────────
Write-Step "Checking prerequisites (architecture: $archLabel, configuration: $Configuration)..."

Assert-CommandOnPath "cargo" "Install the Rust toolchain with https://rustup.rs and reopen your shell."
Assert-CommandOnPath "rustc" "Install the Rust toolchain with https://rustup.rs and reopen your shell."

if ($cargoTarget) {
  $installedTargets = & rustup target list --installed 2>$null
  if ($LASTEXITCODE -ne 0 -or ($installedTargets -notcontains $cargoTarget)) {
    throw "Rust target '$cargoTarget' is not installed. Run: rustup target add $cargoTarget"
  }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
  throw "Visual Studio Installer was not found at '$vswhere'.`nInstall Visual Studio 2022 (Community or Build Tools) with the 'Desktop development with C++' workload (MSVC tools + Windows 10/11 SDK)."
}

$vsComponent = if ($linkerArch -eq "arm64") {
  "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
} else {
  "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
}
$vsInstall = & $vswhere -latest -products * -requires $vsComponent -property installationPath 2>$null
if ([string]::IsNullOrWhiteSpace($vsInstall)) {
  throw "No Visual Studio installation with the MSVC $linkerArch tools was found.`nInstall the 'Desktop development with C++' workload (component: $vsComponent) in Visual Studio Installer."
}

$sdkRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Lib"
if (-not (Test-Path -LiteralPath $sdkRoot)) {
  throw "Windows SDK not found at '$sdkRoot'.`nInstall the Windows 10/11 SDK component in Visual Studio Installer."
}

Write-Host "  - cargo:    $((Get-Command cargo).Source)"
Write-Host "  - MSVC:     $vsInstall"
Write-Host "  - Windows SDK: $sdkRoot"

# ── Build ──────────────────────────────────────────────────────────────────
Write-Step "Building gitcomet ($Features)..."
Write-Host "This is a large GpUI application; a first Release build can take several minutes."

# scripts/windows/msvc-linker.cmd reads this to pick the MSVC/SDK architecture.
$env:GITCOMET_TARGET_ARCH = $linkerArch

$cargoArgs = @("build", "-p", "gitcomet", "--bin", "gitcomet", "--features", $Features)
switch ($Configuration) {
  "Release"         { $cargoArgs += "--release" }
  "ReleaseWithDebug" { $cargoArgs += "--profile", "release-with-debug" }
  "Debug"           { } # default dev profile
}
if (-not $SkipLocked) {
  $cargoArgs += "--locked"
}
if ($cargoTarget) {
  $cargoArgs += "--target", $cargoTarget
}

Write-Host ""
Write-Host "> cargo $($cargoArgs -join ' ')" -ForegroundColor DarkGray
& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) {
  throw "cargo build failed with exit code $LASTEXITCODE."
}

$profileDir = switch ($Configuration) {
  "Release"         { "release" }
  "ReleaseWithDebug" { "release-with-debug" }
  "Debug"           { "debug" }
}
if ($cargoTarget) {
  $binaryPath = Join-Path $targetDir (Join-Path $cargoTarget (Join-Path $profileDir "gitcomet.exe"))
} else {
  $binaryPath = Join-Path $targetDir (Join-Path $profileDir "gitcomet.exe")
}

if (-not (Test-Path -LiteralPath $binaryPath)) {
  throw "Expected binary not found at '$binaryPath'."
}

$sizeMb = [math]::Round((Get-Item -LiteralPath $binaryPath).Length / 1MB, 1)
Write-Host ""
Write-Host "Build succeeded: $binaryPath ($sizeMb MiB)" -ForegroundColor Green

# ── Optional portable packaging ────────────────────────────────────────────
if ($Package) {
  Write-Step "Packaging portable ZIP..."

  $cargoToml = Get-Content -Raw (Join-Path $repoRoot "Cargo.toml")
  $versionMatch = [regex]::Match($cargoToml, '(?ms)\[workspace\.package\][^\[]*?version\s*=\s*"([^"]+)"')
  if (-not $versionMatch.Success) {
    throw "Could not determine the workspace version from Cargo.toml."
  }
  $version = $versionMatch.Groups[1].Value

  $distDir = Join-Path $repoRoot "dist"
  $portableDir = Join-Path $distDir "portable"
  $zipName = "gitcomet-v${version}-windows-${archLabel}-portable.zip"
  $zipPath = Join-Path $distDir $zipName

  New-Item -ItemType Directory -Path $portableDir -Force | Out-Null
  Copy-Item -LiteralPath $binaryPath -Destination (Join-Path $portableDir "gitcomet.exe") -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "README.md") -Destination (Join-Path $portableDir "README.md") -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE-AGPL-3.0") -Destination (Join-Path $portableDir "LICENSE-AGPL-3.0") -Force
  Copy-Item -LiteralPath (Join-Path $repoRoot "NOTICE") -Destination (Join-Path $portableDir "NOTICE") -Force

  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  Compress-Archive -Path (Join-Path $portableDir "*") -DestinationPath $zipPath

  Write-Host ""
  Write-Host "Packaged: $zipPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
