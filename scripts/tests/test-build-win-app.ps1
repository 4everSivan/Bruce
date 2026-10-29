$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sourceScript = Join-Path $repoRoot "scripts\build-win-app.ps1"
$sourceConfig = Join-Path $repoRoot "apps\win\src-tauri\tauri.conf.json"
$pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
$tauriConfig = Get-Content -LiteralPath $sourceConfig -Raw | ConvertFrom-Json
$hostTarget = "x86_64-pc-windows-msvc"
$targetArchitecture = "x64"
$setupName = "{0}_{1}_{2}-setup.exe" -f $tauriConfig.productName, $tauriConfig.version, $targetArchitecture
$testRoot = Join-Path (Join-Path $repoRoot "local\tests") "build-win-app-$([guid]::NewGuid().ToString('N'))"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-BuildFixture {
    param([Parameter(Mandatory = $true)][string]$Name)

    $root = Join-Path $testRoot $Name
    $scripts = Join-Path $root "scripts"
    $tauriRoot = Join-Path $root "apps\win\src-tauri"
    $bin = Join-Path $root "fake-bin"
    $cargoHome = Join-Path $root "cargo-home"
    $dist = Join-Path $root "local\dist"
    $targetRoot = Join-Path $root "local\build-win\cargo-target"
    $target = Join-Path $targetRoot (Join-Path $hostTarget "release")
    foreach ($directory in @($scripts, $tauriRoot, $bin, $cargoHome)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $scripts "build-win-app.ps1")
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $sourceConfig -Destination (Join-Path $tauriRoot "tauri.conf.json")

    $cargoStub = @'
@echo off
if not "%BRUCE_BUILD_TEST_EXIT_CODE%"=="0" exit /b %BRUCE_BUILD_TEST_EXIT_CODE%
if /I "%1"=="install" if "%BRUCE_BUILD_TEST_INSTALL_TAURI%"=="1" (
  if not exist "%CARGO_HOME%\bin" mkdir "%CARGO_HOME%\bin"
  >"%CARGO_HOME%\bin\cargo-tauri.cmd" echo @echo off
  >>"%CARGO_HOME%\bin\cargo-tauri.cmd" echo exit /b 0
  exit /b 0
)
if not "%BRUCE_BUILD_TEST_CREATE_ARTIFACT%"=="1" goto :done
if "%BRUCE_BUILD_TEST_KIND%"=="raw" goto :raw
set "TARGET_DIR=%CARGO_TARGET_DIR%"
if not "%BRUCE_BUILD_TEST_TARGET_SUBDIR%"=="" set "TARGET_DIR=%TARGET_DIR%\%BRUCE_BUILD_TEST_TARGET_SUBDIR%"
if not exist "%TARGET_DIR%\release\bundle\nsis" mkdir "%TARGET_DIR%\release\bundle\nsis"
>"%TARGET_DIR%\release\bundle\nsis\%BRUCE_BUILD_TEST_SETUP_NAME%" echo fake-successful-installer
>"%TARGET_DIR%\release\bundle\nsis\%BRUCE_BUILD_TEST_SETUP_NAME%.sig" echo fake-successful-signature
goto :done
:raw
set "TARGET_DIR=%CARGO_TARGET_DIR%"
if not "%BRUCE_BUILD_TEST_TARGET_SUBDIR%"=="" set "TARGET_DIR=%TARGET_DIR%\%BRUCE_BUILD_TEST_TARGET_SUBDIR%"
if not exist "%TARGET_DIR%\release" mkdir "%TARGET_DIR%\release"
>"%TARGET_DIR%\release\bruce-win.exe" echo fake-successful-executable
:done
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $bin "cargo.cmd") -Value $cargoStub -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $bin "cargo-tauri.cmd") -Value "@echo off`r`nexit /b 0`r`n" -Encoding Ascii
    Set-Content -LiteralPath (Join-Path $bin "rustc.cmd") -Value "@echo off`r`necho rustc 1.0.0`r`necho host: %BRUCE_BUILD_TEST_RUSTC_HOST%`r`nexit /b 0`r`n" -Encoding Ascii

    return [pscustomobject]@{
        Root = $root
        ScriptPath = Join-Path $scripts "build-win-app.ps1"
        Bin = $bin
        CargoHome = $cargoHome
        Dist = $dist
        TargetRoot = $targetRoot
        Target = $target
        SetupPath = Join-Path (Join-Path $target "bundle\nsis") $setupName
        SetupName = $setupName
    }
}

function Set-FixtureArtifact {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][ValidateSet("raw", "installer")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Contents,
        [datetime]$ModifiedAt = [datetime]::new(2010, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
    )

    if ($Kind -eq "raw") {
        $path = Join-Path $Fixture.Target $Name
    }
    else {
        $nsis = Join-Path $Fixture.Target "bundle\nsis"
        New-Item -ItemType Directory -Force -Path $nsis | Out-Null
        $path = Join-Path $nsis $Name
    }
    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($path, $Contents)
    [System.IO.File]::SetLastWriteTimeUtc($path, $ModifiedAt)
    return $path
}

function Invoke-BuildFixture {
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [Parameter(Mandatory = $true)][ValidateSet("raw", "installer")][string]$Kind,
        [Parameter(Mandatory = $true)][int]$CargoExitCode,
        [switch]$CreateArtifact,
        [switch]$SigningEnabled,
        [switch]$TauriCliMissing,
        [switch]$InstallTauri,
        [string]$CargoBuildTarget = "",
        [string]$TargetSubdirectory = "",
        [string]$CargoTargetDirectory = "",
        [string[]]$ScriptArguments = @()
    )

    $environmentNames = @(
        "PATH",
        "BRUCE_BUILD_TEST_EXIT_CODE",
        "BRUCE_BUILD_TEST_CREATE_ARTIFACT",
        "BRUCE_BUILD_TEST_INSTALL_TAURI",
        "BRUCE_BUILD_TEST_KIND",
        "BRUCE_BUILD_TEST_RUSTC_HOST",
        "BRUCE_BUILD_TEST_TARGET_SUBDIR",
        "BRUCE_BUILD_TEST_SETUP_NAME",
        "CARGO_HOME",
        "CARGO_BUILD_TARGET",
        "CARGO_TARGET_DIR",
        "TAURI_SIGNING_PRIVATE_KEY",
        "TAURI_SIGNING_PRIVATE_KEY_PASSWORD"
    )
    $originalEnvironment = @{}
    foreach ($name in $environmentNames) {
        $originalEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
    }

    try {
        if ($TauriCliMissing) {
            Remove-Item -LiteralPath (Join-Path $Fixture.Bin "cargo-tauri.cmd") -ErrorAction SilentlyContinue
            $env:PATH = "$($Fixture.Bin);$env:SystemRoot\System32;$env:SystemRoot"
        }
        else {
            $env:PATH = "$($Fixture.Bin);$($originalEnvironment['PATH'])"
        }
        $env:BRUCE_BUILD_TEST_EXIT_CODE = [string]$CargoExitCode
        $env:BRUCE_BUILD_TEST_CREATE_ARTIFACT = if ($CreateArtifact) { "1" } else { "0" }
        $env:BRUCE_BUILD_TEST_INSTALL_TAURI = if ($InstallTauri) { "1" } else { "0" }
        $env:BRUCE_BUILD_TEST_KIND = $Kind
        $env:BRUCE_BUILD_TEST_RUSTC_HOST = $hostTarget
        if ([string]::IsNullOrWhiteSpace($TargetSubdirectory)) {
            $TargetSubdirectory = if ([string]::IsNullOrWhiteSpace($CargoBuildTarget)) { $hostTarget } else { $CargoBuildTarget }
        }
        $env:BRUCE_BUILD_TEST_TARGET_SUBDIR = $TargetSubdirectory
        $env:BRUCE_BUILD_TEST_SETUP_NAME = $Fixture.SetupName
        $env:CARGO_HOME = $Fixture.CargoHome
        $env:CARGO_BUILD_TARGET = $CargoBuildTarget
        if ([string]::IsNullOrWhiteSpace($CargoTargetDirectory)) {
            $CargoTargetDirectory = Join-Path $Fixture.Root "local\build-win\cargo-target"
        }
        $env:CARGO_TARGET_DIR = $CargoTargetDirectory
        $env:TAURI_SIGNING_PRIVATE_KEY = if ($SigningEnabled) { "fixture-only-key" } else { $null }
        $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = $null

        $output = & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $Fixture.ScriptPath @ScriptArguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }
    finally {
        foreach ($name in $environmentNames) {
            [System.Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], "Process")
        }
    }
}

function Assert-BuildFailed {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Scenario
    )

    Assert-True ($Result.ExitCode -ne 0) "$Scenario 应以非零退出码失败, 实际输出:`n$($Result.Output)"
    Assert-True (-not $Result.Output.Contains("Bruce Windows 打包完成")) "$Scenario 不得输出打包完成"
}

try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $testRoot) | Out-Null
    New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop | Out-Null

    # tauri-cli 缺失时安装命令失败, 不得继续尝试打包或复制旧安装包。
    $installFailure = New-BuildFixture "tauri-cli-install-failed"
    Set-FixtureArtifact $installFailure "installer" $setupName "stale-installer-before-install" | Out-Null
    $result = Invoke-BuildFixture $installFailure "installer" 22 -TauriCliMissing
    Assert-BuildFailed $result "tauri-cli 安装失败"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installFailure.Dist $setupName))) "tauri-cli 安装失败不得复制旧安装包"
    Assert-True ($result.Output.Contains("Exit Code: 22")) "tauri-cli 安装失败应保留 cargo 退出码"
    Write-Host "ok: tauri-cli 安装失败立即终止"

    $installSuccess = New-BuildFixture "tauri-cli-install-success"
    $result = Invoke-BuildFixture $installSuccess "installer" 0 -TauriCliMissing -InstallTauri -CreateArtifact
    Assert-True ($result.ExitCode -eq 0) "安装到 CARGO_HOME/bin 的 tauri-cli 应可被后续命令发现, 实际输出:`n$($result.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $installSuccess.Dist $setupName)) "tauri-cli 安装后应完成安装包构建"
    Write-Host "ok: cargo install 后通过 CARGO_HOME/bin 发现 cargo-tauri 并完成构建"

    # Cargo 失败时, 预置的旧裸程序不得被复制到 local/dist。
    $rawFailure = New-BuildFixture "raw-failed-with-stale-output"
    Set-FixtureArtifact $rawFailure "raw" "bruce-win.exe" "stale-executable" | Out-Null
    $result = Invoke-BuildFixture $rawFailure "raw" 23 -ScriptArguments @("-SkipInstaller")
    Assert-BuildFailed $result "裸程序构建失败"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rawFailure.Dist "bruce-win.exe"))) "裸程序构建失败不得复制旧文件"
    Assert-True ($result.Output.Contains("Exit Code: 23")) "裸程序失败应保留 cargo 退出码"
    Write-Host "ok: cargo 失败时不复制预置旧裸程序"

    # NSIS 失败时, 预置旧版本安装包即使时间更新也不得被复制。
    $installerFailure = New-BuildFixture "installer-failed-with-newer-stale-output"
    $staleSetupName = "{0}_0.13.0_{1}-setup.exe" -f $tauriConfig.productName, $targetArchitecture
    $newer = [datetime]::new(2025, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
    Set-FixtureArtifact $installerFailure "installer" $staleSetupName "newer-stale-installer" $newer | Out-Null
    Set-FixtureArtifact $installerFailure "installer" "$staleSetupName.sig" "stale-signature" $newer.AddMinutes(1) | Out-Null
    $result = Invoke-BuildFixture $installerFailure "installer" 24
    Assert-BuildFailed $result "NSIS 构建失败"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installerFailure.Dist $staleSetupName))) "NSIS 构建失败不得复制旧安装包"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installerFailure.Dist "$staleSetupName.sig"))) "NSIS 构建失败不得复制旧签名"
    Assert-True ($result.Output.Contains("Exit Code: 24")) "NSIS 失败应保留 cargo 退出码"
    Write-Host "ok: cargo 失败时不复制时间更新的旧版本安装包或签名"

    # cargo 成功但缺少目标文件时, 不得把其他版本的旧安装包当成产物。
    $missingInstaller = New-BuildFixture "installer-missing-current-version"
    Set-FixtureArtifact $missingInstaller "installer" $staleSetupName "wrong-version-installer" $newer | Out-Null
    $result = Invoke-BuildFixture $missingInstaller "installer" 0
    Assert-BuildFailed $result "当前版本安装包缺失"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingInstaller.Dist $staleSetupName))) "缺少当前版本安装包时不得复制旧版本"
    Assert-True ($result.Output.Contains($missingInstaller.SetupName)) "缺少产物错误应指出预期文件名"
    Write-Host "ok: 缺少当前版本安装包时拒绝选择其他版本"

    $missingRaw = New-BuildFixture "raw-missing-output"
    $result = Invoke-BuildFixture $missingRaw "raw" 0 -ScriptArguments @("-SkipInstaller")
    Assert-BuildFailed $result "裸程序产物缺失"
    Assert-True ($result.Output.Contains("bruce-win.exe")) "裸程序缺失错误应指出预期文件"
    Write-Host "ok: cargo 成功但裸程序缺失时失败"

    $newRaw = New-BuildFixture "raw-new-output-success"
    $result = Invoke-BuildFixture $newRaw "raw" 0 -CreateArtifact -ScriptArguments @("-SkipInstaller")
    Assert-True ($result.ExitCode -eq 0) "新建裸程序应成功收拢, 实际输出:`n$($result.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $newRaw.Dist "bruce-win.exe")) "应复制本次新建的裸程序"
    Write-Host "ok: cargo 新建裸程序后成功收拢"

    # 增量构建可以不改写文件时间; cargo 成功并存在的当前版本/架构产物仍应被接受。
    $successfulRaw = New-BuildFixture "raw-incremental-success"
    $rawPath = Set-FixtureArtifact $successfulRaw "raw" "bruce-win.exe" "incremental-current-executable"
    $result = Invoke-BuildFixture $successfulRaw "raw" 0 -ScriptArguments @("-SkipInstaller")
    Assert-True ($result.ExitCode -eq 0) "成功的增量裸程序构建应通过, 实际输出:`n$($result.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $successfulRaw.Dist "bruce-win.exe") -Raw) -eq "incremental-current-executable") "增量构建应复制 cargo 成功对应的现有文件"
    Assert-True ([System.IO.File]::GetLastWriteTimeUtc($rawPath) -eq [datetime]::new(2010, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)) "测试前置文件时间应保持不变"
    Assert-True ($result.Output.Contains("Bruce Windows 打包完成")) "成功路径应输出完成"
    Write-Host "ok: 未更新时间戳的增量裸程序构建成功并收拢产物"

    $successfulInstaller = New-BuildFixture "installer-incremental-exact-version"
    $setupPath = Set-FixtureArtifact $successfulInstaller "installer" $setupName "current-version-installer"
    Set-FixtureArtifact $successfulInstaller "installer" "$setupName.sig" "current-version-signature" ([datetime]::new(2010, 1, 2, 3, 5, 5, [DateTimeKind]::Utc)) | Out-Null
    Set-FixtureArtifact $successfulInstaller "installer" $staleSetupName "newer-old-version-installer" $newer | Out-Null
    $result = Invoke-BuildFixture $successfulInstaller "installer" 0
    Assert-True ($result.ExitCode -eq 0) "成功的增量 NSIS 构建应通过, 实际输出:`n$($result.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $successfulInstaller.Dist $setupName) -Raw) -eq "current-version-installer") "应复制配置版本与目标架构相符的安装包"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $successfulInstaller.Dist $staleSetupName))) "不得按最新时间复制其他版本安装包"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $successfulInstaller.Dist "$setupName.sig"))) "--no-sign 构建不得复制同路径残留的旧签名"
    Assert-True ($result.Output.Contains("Bruce Windows 打包完成")) "成功路径应输出完成"
    Write-Host "ok: --no-sign 增量构建选中配置版本, 忽略新时间旧版本和残留签名"

    $staleDistSignature = New-BuildFixture "no-sign-existing-dist-signature"
    Set-FixtureArtifact $staleDistSignature "installer" $setupName "new-current-installer"
    New-Item -ItemType Directory -Force -Path $staleDistSignature.Dist | Out-Null
    $existingDistSetup = Join-Path $staleDistSignature.Dist $setupName
    $existingDistSignature = Join-Path $staleDistSignature.Dist "$setupName.sig"
    [System.IO.File]::WriteAllText($existingDistSetup, "existing-dist-installer")
    [System.IO.File]::WriteAllText($existingDistSignature, "stale-dist-signature")
    $result = Invoke-BuildFixture $staleDistSignature "installer" 0
    Assert-BuildFailed $result "--no-sign 目标目录残留旧签名"
    Assert-True ((Get-Content -LiteralPath $existingDistSetup -Raw) -eq "existing-dist-installer") "发现旧签名时不得先覆盖 local/dist 安装包"
    Assert-True ((Get-Content -LiteralPath $existingDistSignature -Raw) -eq "stale-dist-signature") "旧签名应保留供维护者处理"
    Write-Host "ok: --no-sign 遇到 local/dist 同名旧签名时阻止安装包收拢且保留现场"

    # 显式 Cargo 目标优先于 rustc host triple, 并选取该目标专属的 Cargo 输出目录。
    $arm64Fixture = New-BuildFixture "installer-explicit-arm64-target"
    $arm64Triple = "aarch64-pc-windows-msvc"
    $arm64Name = "{0}_{1}_arm64-setup.exe" -f $tauriConfig.productName, $tauriConfig.version
    $arm64Release = Join-Path $arm64Fixture.TargetRoot (Join-Path $arm64Triple "release")
    $arm64Nsis = Join-Path $arm64Release "bundle\nsis"
    New-Item -ItemType Directory -Force -Path $arm64Nsis | Out-Null
    $arm64Path = Join-Path $arm64Nsis $arm64Name
    [System.IO.File]::WriteAllText($arm64Path, "arm64-current-installer")
    $arm64Fixture.SetupName = $arm64Name
    $arm64Fixture.SetupPath = $arm64Path
    $result = Invoke-BuildFixture $arm64Fixture "installer" 0 -CargoBuildTarget $arm64Triple
    Assert-True ($result.ExitCode -eq 0) "显式 ARM64 Cargo 目标应选中对应安装包, 实际输出:`n$($result.Output)"
    Assert-True ((Get-Content -LiteralPath (Join-Path $arm64Fixture.Dist $arm64Name) -Raw) -eq "arm64-current-installer") "应按 CARGO_BUILD_TARGET 选择 ARM64 包"
    Write-Host "ok: CARGO_BUILD_TARGET 覆盖 Rust host 并选择对应架构/target 目录"

    $customTarget = New-BuildFixture "custom-cargo-target-rejected"
    $result = Invoke-BuildFixture $customTarget "installer" 0 -CargoBuildTarget "custom-target.json"
    Assert-BuildFailed $result "自定义 Cargo target"
    Assert-True ($result.Output.Contains("不支持无法可靠解析的自定义 Cargo target")) "自定义 target 应明确失败而不是猜架构"
    Write-Host "ok: 无法可靠识别的自定义 Cargo target 明确失败"

    $externalTarget = New-BuildFixture "external-cargo-target-rejected"
    $externalTargetPath = Join-Path $testRoot "outside-local-cargo-target"
    $result = Invoke-BuildFixture $externalTarget "raw" 0 -CargoTargetDirectory $externalTargetPath -ScriptArguments @("-SkipInstaller")
    Assert-BuildFailed $result "仓库 local 之外的 Cargo target"
    Assert-True ($result.Output.Contains("CARGO_TARGET_DIR 必须位于仓库 local/ 内")) "仓库 local 外的 target 应明确拒绝"
    Assert-True (-not (Test-Path -LiteralPath $externalTargetPath)) "拒绝外部 target 时不得创建目录"
    Write-Host "ok: 构建输出被限制在 local/ 下"

    $signedInstaller = New-BuildFixture "installer-signed-success"
    Set-FixtureArtifact $signedInstaller "installer" $setupName "signed-current-installer" | Out-Null
    Set-FixtureArtifact $signedInstaller "installer" "$setupName.sig" "signed-current-signature" ([datetime]::new(2010, 1, 2, 3, 5, 5, [DateTimeKind]::Utc)) | Out-Null
    $result = Invoke-BuildFixture $signedInstaller "installer" 0 -SigningEnabled
    Assert-True ($result.ExitCode -eq 0) "签名构建成功路径应通过, 实际输出:`n$($result.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $signedInstaller.Dist "$setupName.sig")) "签名模式应收拢符合时间检查的签名文件"
    Write-Host "ok: 签名模式收拢符合时间检查的同名签名文件"

    # 锁定已有目标文件以制造真实文件系统复制失败, 验证错误会传播且不会报告完成。
    $copyFailure = New-BuildFixture "raw-copy-failure"
    Set-FixtureArtifact $copyFailure "raw" "bruce-win.exe" "new-executable" | Out-Null
    New-Item -ItemType Directory -Force -Path $copyFailure.Dist | Out-Null
    $lockedDestination = Join-Path $copyFailure.Dist "bruce-win.exe"
    [System.IO.File]::WriteAllText($lockedDestination, "locked-old-destination")
    $lock = [System.IO.File]::Open($lockedDestination, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $result = Invoke-BuildFixture $copyFailure "raw" 0 -CreateArtifact -ScriptArguments @("-SkipInstaller")
    }
    finally {
        $lock.Dispose()
    }
    Assert-BuildFailed $result "产物复制失败"
    Write-Host "ok: 文件系统复制失败会传播且不会报告打包完成"
}
finally {
    Write-Host "行为测试 fixture 保留于: $testRoot"
}

Write-Host "Windows 本地打包行为测试通过"
