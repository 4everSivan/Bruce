# Bruce Windows 本地打包脚本 (T04-1)。
# 产物一律收拢到仓库 local/dist (AGENTS.md 本地隔离红线), 不污染源码树。
# 用法: powershell -ExecutionPolicy Bypass -File scripts/build-win-app.ps1 [-SkipInstaller] [-RequireUpdateSignature]
param(
    [switch]$SkipInstaller,
    [switch]$RequireUpdateSignature
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$distDir = Join-Path $repoRoot "local\dist"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

Set-Location (Join-Path $repoRoot "apps\win\src-tauri")

$cargoHomeDirectory = $env:CARGO_HOME
if ([string]::IsNullOrWhiteSpace($cargoHomeDirectory)) {
    $cargoHomeDirectory = Join-Path $env:USERPROFILE ".cargo"
}
$cargoBinDirectory = Join-Path $cargoHomeDirectory "bin"
if (($env:PATH -split [System.IO.Path]::PathSeparator) -notcontains $cargoBinDirectory) {
    $env:PATH = "$cargoBinDirectory$([System.IO.Path]::PathSeparator)$env:PATH"
}

function Invoke-CargoChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CargoArguments
    )

    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        throw "未找到 cargo 命令, 无法构建 Windows App"
    }

    & cargo @CargoArguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "cargo $($CargoArguments -join ' ') 失败 (Exit Code: $exitCode)"
    }
}

function Get-CargoBuildInfo {
    if (-not (Get-Command rustc -ErrorAction SilentlyContinue)) {
        throw "未找到 rustc 命令, 无法判定 Cargo 主机目标"
    }
    $rustcDetails = & rustc -vV
    $rustcExitCode = $LASTEXITCODE
    if ($rustcExitCode -ne 0) {
        throw "rustc -vV 失败 (Exit Code: $rustcExitCode), 无法判定 Cargo 主机目标"
    }
    $hostMatch = [regex]::Match(($rustcDetails -join "`n"), '(?m)^host:\s*(\S+)\s*$')
    if (-not $hostMatch.Success) {
        throw "rustc -vV 输出未包含 host 三元组, 无法判定 Cargo 主机目标"
    }
    $hostTarget = $hostMatch.Groups[1].Value
    $target = $env:CARGO_BUILD_TARGET
    if ([string]::IsNullOrWhiteSpace($target)) { $target = $hostTarget }

    if ($target -match '[/\\]' -or $target.EndsWith(".json", [StringComparison]::OrdinalIgnoreCase)) {
        throw "不支持无法可靠解析的自定义 Cargo target '$target'; 请配置 CARGO_BUILD_TARGET 为 Windows target 三元组"
    }
    if ($target -notmatch '(^|-)windows(-|$)') {
        throw "Cargo 构建目标不是 Windows target 三元组: $target"
    }

    $architecture = switch -Regex ($target) {
        '^(x86_64|x64)([-_.]|$)' { "x64"; break }
        '^(aarch64|arm64)([-_.]|$)' { "arm64"; break }
        '^(i[3-6]86|x86)([-_.]|$)' { "x86"; break }
        default { throw "无法识别 Windows 构建目标架构: $target" }
    }

    return [pscustomobject]@{
        HostTriple = $hostTarget
        TargetTriple = $target
        TargetDirectoryName = $target
        Architecture = $architecture
    }
}

function Get-CargoReleaseDirectory {
    param([string]$TargetDirectoryName)

    $targetDirectory = $env:CARGO_TARGET_DIR
    if ([string]::IsNullOrWhiteSpace($targetDirectory)) {
        $targetDirectory = "target"
    }

    if (-not [System.IO.Path]::IsPathRooted($targetDirectory)) {
        $targetDirectory = Join-Path (Get-Location).Path $targetDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetDirectoryName)) {
        $targetDirectory = Join-Path $targetDirectory $TargetDirectoryName
    }
    return Join-Path $targetDirectory "release"
}

$localRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "local"))
$localPrefix = $localRoot.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
$configuredCargoTargetDirectory = $env:CARGO_TARGET_DIR
if ([string]::IsNullOrWhiteSpace($configuredCargoTargetDirectory)) {
    $cargoTargetDirectory = Join-Path $localRoot "build-win\cargo-target"
}
elseif ([System.IO.Path]::IsPathRooted($configuredCargoTargetDirectory)) {
    $cargoTargetDirectory = [System.IO.Path]::GetFullPath($configuredCargoTargetDirectory)
}
else {
    $cargoTargetDirectory = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $configuredCargoTargetDirectory))
}
if ($cargoTargetDirectory -ne $localRoot -and
    -not $cargoTargetDirectory.StartsWith($localPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "CARGO_TARGET_DIR 必须位于仓库 local/ 内: $cargoTargetDirectory"
}
$env:CARGO_TARGET_DIR = $cargoTargetDirectory
New-Item -ItemType Directory -Force -Path $cargoTargetDirectory | Out-Null
$cargoBuildInfo = Get-CargoBuildInfo
$copiedArtifacts = @()
Write-Host "Windows 构建目标: $($cargoBuildInfo.TargetTriple) (Rust host: $($cargoBuildInfo.HostTriple))"

if (-not $SkipInstaller) {
    # tauri-cli 驱动完整打包 (NSIS 安装包, 内置 WebView2 Bootstrapper)。
    # 钉版纪律 (C036): --locked 只钉 CLI 自身依赖树, 不钉 CLI 版本本身; 版本须与
    # CI release-windows 作业一致 (2.12.2 = v0.11.5 发布实测通过的版本), 否则本地与
    # CI 打包链路漂移。升版必须两端同步并随下一次 tag 发布验证。
    if (-not (Get-Command cargo-tauri -ErrorAction SilentlyContinue)) {
        Write-Host "安装 tauri-cli 2.12.2 (一次性, 约 3-6 分钟)..."
        Invoke-CargoChecked -CargoArguments @("install", "tauri-cli", "--version", "=2.12.2", "--locked", "--target", $cargoBuildInfo.HostTriple)
        if (-not (Get-Command cargo-tauri -ErrorAction SilentlyContinue)) {
            throw "cargo install tauri-cli 成功但 cargo-tauri 未出现在 PATH ($cargoBinDirectory)"
        }
    }
    # T09: 要求产出可推送更新的签名包时, 缺私钥显式失败 (与 CI release-windows 门禁同口径)。
    # tauri.conf.json 已开启 createUpdaterArtifacts, 无私钥时 tauri build 会直接报错; 日常
    # 本地构建因此以 --no-sign 跳过更新签名 (此类包不可用于推送更新)。
    if ($RequireUpdateSignature -and -not $env:TAURI_SIGNING_PRIVATE_KEY) {
        Write-Error "缺少 TAURI_SIGNING_PRIVATE_KEY 环境变量, 拒绝产出未签名安装包 (-RequireUpdateSignature)"
        exit 1
    }
    if ($env:TAURI_SIGNING_PRIVATE_KEY) {
        Invoke-CargoChecked -CargoArguments @("tauri", "build", "--target", $cargoBuildInfo.TargetTriple, "--bundles", "nsis")
    }
    else {
        Write-Host "未设置 TAURI_SIGNING_PRIVATE_KEY: 以 --no-sign 构建, 不产出更新签名"
        Invoke-CargoChecked -CargoArguments @("tauri", "build", "--target", $cargoBuildInfo.TargetTriple, "--bundles", "nsis", "--no-sign")
    }
    # LastWriteTime 不能证明是否为本轮有效输出: Cargo 增量构建可能成功复用未改写的文件。
    # 因此先要求本次命令成功, 再按配置版本与实际目标架构精确选择文件, 不按目录最新时间猜测。
    $tauriConfigPath = Join-Path $PSScriptRoot "..\apps\win\src-tauri\tauri.conf.json"
    if (-not (Test-Path -LiteralPath $tauriConfigPath -PathType Leaf)) {
        throw "Tauri 配置文件不存在: $tauriConfigPath"
    }
    $tauriConfig = Get-Content -LiteralPath $tauriConfigPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$tauriConfig.productName) -or
        [string]::IsNullOrWhiteSpace([string]$tauriConfig.version)) {
        throw "Tauri 配置缺少 productName 或 version: $tauriConfigPath"
    }
    $expectedSetupName = "{0}_{1}_{2}-setup.exe" -f $tauriConfig.productName, $tauriConfig.version, $cargoBuildInfo.Architecture
    $releaseDirectory = Get-CargoReleaseDirectory -TargetDirectoryName $cargoBuildInfo.TargetDirectoryName
    $nsisDirectory = Join-Path $releaseDirectory "bundle\nsis"
    $setupPath = Join-Path $nsisDirectory $expectedSetupName
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "cargo tauri build 成功但未找到本次目标安装包 $expectedSetupName ($nsisDirectory)"
    }

    # 有私钥不等于有签名: tauri.conf.json 未开 updater 产物或缺公钥时不会生成 .sig。
    # 这里只检查签名文件存在且不早于精确安装包, 不做密码学验签或本次增量构建的新旧判断。
    $sig = "$setupPath.sig"
    $setup = Get-Item -LiteralPath $setupPath
    $signingEnabled = -not [string]::IsNullOrWhiteSpace($env:TAURI_SIGNING_PRIVATE_KEY)
    $sigTimestampOk = $signingEnabled -and (Test-Path -LiteralPath $sig -PathType Leaf) -and
        ((Get-Item -LiteralPath $sig).LastWriteTime -ge $setup.LastWriteTime)
    if ($RequireUpdateSignature -and -not $sigTimestampOk) {
        throw "未找到不早于目标安装包的签名文件 $expectedSetupName.sig (检查 bundle.createUpdaterArtifacts 与 plugins.updater.pubkey); 此处仅检查存在性与时间戳, 不执行密码学验签"
    }
    $distSignature = Join-Path $distDir (Split-Path -Leaf $sig)
    if (-not $signingEnabled -and (Test-Path -LiteralPath $distSignature)) {
        throw "--no-sign 构建拒绝与 local\dist 中的旧签名并存: $distSignature; 请由维护者处理该既有产物后重试"
    }

    Copy-Item -LiteralPath $setup.FullName -Destination $distDir -ErrorAction Stop
    $copiedArtifacts += Join-Path $distDir $setup.Name
    Write-Host "安装包: $($setup.Name) -> local\dist"
    if ($sigTimestampOk) {
        Copy-Item -LiteralPath $sig -Destination $distDir -ErrorAction Stop
        $copiedArtifacts += Join-Path $distDir (Split-Path -Leaf $sig)
        Write-Host "更新签名: $($setup.Name).sig -> local\dist"
    }
}
else {
    Invoke-CargoChecked -CargoArguments @("build", "--target", $cargoBuildInfo.TargetTriple, "--release")
    $exePath = Join-Path (Get-CargoReleaseDirectory -TargetDirectoryName $cargoBuildInfo.TargetDirectoryName) "bruce-win.exe"
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "cargo build 成功但未找到可执行文件: $exePath"
    }
    Copy-Item -LiteralPath $exePath -Destination $distDir -ErrorAction Stop
    $copiedArtifacts += Join-Path $distDir (Split-Path -Leaf $exePath)
    Write-Host "裸可执行文件 -> local\dist"
}

# SHA256 校验和。
foreach ($artifactPath in $copiedArtifacts) {
    $artifact = Get-Item -LiteralPath $artifactPath -ErrorAction Stop
    $hash = (Get-FileHash $artifact.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
    Write-Host "SHA256  $hash  $($artifact.Name)"
}
Write-Host "Bruce Windows 打包完成"
