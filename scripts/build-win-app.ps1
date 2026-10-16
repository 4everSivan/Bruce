# Bruce Windows 本地打包脚本 (T04-1)。
# 产物一律收拢到仓库 local/dist (AGENTS.md 本地隔离红线), 不污染源码树。
# 用法: powershell -ExecutionPolicy Bypass -File scripts/build-win-app.ps1 [-SkipInstaller]
param(
    [switch]$SkipInstaller
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
    cargo tauri build --bundles nsis
    $setup = Get-ChildItem -Path "target\release\bundle\nsis" -Filter "*-setup.exe" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($setup) {
        Copy-Item $setup.FullName $distDir
        Write-Host "安装包: $($setup.Name) -> local\dist"
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
