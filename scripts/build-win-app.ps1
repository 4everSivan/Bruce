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

if (-not $SkipInstaller) {
    # tauri-cli 驱动完整打包 (NSIS 安装包, 内置 WebView2 Bootstrapper)。
    # 钉版纪律 (C036): --locked 只钉 CLI 自身依赖树, 不钉 CLI 版本本身; 版本须与
    # CI release-windows 作业一致 (2.12.2 = v0.11.5 发布实测通过的版本), 否则本地与
    # CI 打包链路漂移。升版必须两端同步并随下一次 tag 发布验证。
    if (-not (Get-Command cargo-tauri -ErrorAction SilentlyContinue)) {
        Write-Host "安装 tauri-cli 2.12.2 (一次性, 约 3-6 分钟)..."
        cargo install tauri-cli --version "=2.12.2" --locked
    }
    # T09: 要求产出可推送更新的签名包时, 缺私钥显式失败 (与 CI release-windows 门禁同口径);
    # 不带该开关的日常本地构建不受影响。
    if ($RequireUpdateSignature -and -not $env:TAURI_SIGNING_PRIVATE_KEY) {
        Write-Error "缺少 TAURI_SIGNING_PRIVATE_KEY 环境变量, 拒绝产出未签名安装包 (-RequireUpdateSignature)"
        exit 1
    }
    cargo tauri build --bundles nsis
    $setup = Get-ChildItem -Path "target\release\bundle\nsis" -Filter "*-setup.exe" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($setup) {
        # 有私钥不等于有签名: tauri.conf.json 未开 bundle.createUpdaterArtifacts 或缺
        # plugins.updater.pubkey 时 tauri 不产 .sig; 早于安装包的 .sig 是上一轮构建残留。
        # 因此以本轮产物为准, 在收拢到 local/dist 之前拦截。
        $sig = "$($setup.FullName).sig"
        $sigFresh = (Test-Path $sig) -and ((Get-Item $sig).LastWriteTime -ge $setup.LastWriteTime)
        if ($RequireUpdateSignature -and -not $sigFresh) {
            Write-Error "本轮构建未产出 $($setup.Name).sig (检查 tauri.conf.json 的 bundle.createUpdaterArtifacts 与 plugins.updater.pubkey), 拒绝产出未签名安装包 (-RequireUpdateSignature)"
            exit 1
        }
        Copy-Item $setup.FullName $distDir
        Write-Host "安装包: $($setup.Name) -> local\dist"
        if ($sigFresh) {
            Copy-Item $sig $distDir
            Write-Host "更新签名: $($setup.Name).sig -> local\dist"
        }
    }
}
else {
    cargo build --release
    Copy-Item "target\release\bruce-win.exe" $distDir -ErrorAction SilentlyContinue
    Write-Host "裸可执行文件 -> local\dist"
}

# SHA256 校验和。
Get-ChildItem $distDir -Filter "Bruce*" | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    Write-Host "SHA256  $hash  $($_.Name)"
}
Write-Host "Bruce Windows 打包完成"
