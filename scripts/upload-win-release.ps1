# Bruce Windows 发布资产上传脚本 (T04 / C036)。
# 由 .github/workflows/ci.yml 的 release-windows 作业调用 (tag 触发): 把 NSIS 安装包、
# SHA256 校验和、双平台 minisign 签名 (<setup>.sig / Bruce.zip.sig) 与 latest.json 更新清单
# 上传到 mac 侧 release 作业建好的同 tag 草稿 Release, 随后发布该草稿。
# 需要环境变量 GH_TOKEN 与 TAURI_SIGNING_PRIVATE_KEY / _PASSWORD (签 Bruce.zip)。
#
# 纪律 (C036):
#   1. release 列表必须分页 (--paginate --slurp): 该端点默认 30 条/页, release 总数超过
#      30 后目标草稿不在首页, 查找落空会让上传直接失败;
#   2. 重跑幂等: 同名资产已存在时 POST 返回 422 already_exists (仅重试本作业而不重跑
#      release 作业时, 草稿里往往已有上一轮资产), 上传前先删同名残留;
#   3. 本脚本由 verify-windows 作业的 AST 解析步骤做语法门禁, 非 tag 场景也能被验证;
#   4. (T09) latest.json 在本脚本内生成, 输入取自下面选定的同一个 $release, 与发布目标同源。
#
# 用法 (仓库根目录): pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/upload-win-release.ps1
$ErrorActionPreference = "Stop"

$repo = $env:GITHUB_REPOSITORY
$tag = $env:GITHUB_REF_NAME
if (-not $repo -or -not $tag) {
    Write-Error "缺少 GITHUB_REPOSITORY / GITHUB_REF_NAME 环境变量 (仅限 Release 工作流调用)"
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$setup = Get-ChildItem -Path "apps/win/src-tauri/target/release/bundle/nsis" -Filter "*-setup.exe" |
    Select-Object -First 1
if (-not $setup) {
    Write-Error "NSIS 安装包未找到"
    exit 1
}
$sumFile = "SHA256SUMS-windows.txt"
if (-not (Test-Path $sumFile)) {
    Write-Error "$sumFile 未生成"
    exit 1
}

# 分页拉全量: --paginate 逐页请求, --slurp 把各页收进一个外层数组 (单页时也形如 [[..]]),
# 因此必须逐页展平 —— 直接把 --slurp 结果当 release 列表用会把 upload_url / assets
# 之类的字段取成数组, 拼出的上传 URL 随之损坏。foreach 对「外层数组」与「扁平对象」
# 两种形状都成立, 展平后做一次非空断言兜住 gh api 整体失败。
$pages = gh api --paginate --slurp "repos/$repo/releases?per_page=100" | ConvertFrom-Json
$releases = @()
foreach ($page in $pages) { $releases += $page }
if ($releases.Count -lt 1) {
    Write-Error "release 列表为空 (gh api 未返回任何条目)"
    exit 1
}
# 必须取 created_at 最新的同 tag 草稿: 失败 run 可能残留旧草稿, 列表顺序不确定,
# First-1 可能命中残留把资产传丢。
$release = $releases |
    Where-Object { $_.tag_name -eq $tag } |
    Sort-Object created_at -Descending |
    Select-Object -First 1
if (-not $release) {
    Write-Error "草稿 Release 未找到 (tag=$tag)"
    exit 1
}
Write-Host "上传目标 release id=$($release.id) created=$($release.created_at) draft=$($release.draft)"
$uploadUrl = $release.upload_url -replace '\{.*$',''

# T09: 更新链资产 —— 安装包的 minisign 签名与双平台 latest.json 清单必须随包上传,
# 缺任一即失败 (客户端检查更新依赖 latest.json, 漏传则全员静默无更新)。
$sigFile = "$($setup.FullName).sig"
if (-not (Test-Path $sigFile) -or -not (Get-Content $sigFile -Raw).Trim()) {
    Write-Error "minisign .sig 缺失或为空: $sigFile (未签名产物禁止上传)"
    exit 1
}

# macOS 产物、校验和与发布说明必须按资产 id 从上面选定的 $release 下载, 不得用
# gh release download <tag>: 残留同 tag 草稿时它按 tag 解析到的可能是另一份草稿, 清单里的
# Bruce.zip 哈希会与实际发布的包不符, mac 端 SHA256 校验全员失败。
$macZip = "Bruce.zip"
$notesFile = "release-notes-$($tag -replace '^v', '').md"
foreach ($name in @($macZip, "SHA256SUMS", $notesFile)) {
    $asset = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $asset) {
        Write-Error "目标 release 缺少 macOS 侧资产 $name (release 作业未完成上传?)"
        exit 1
    }
    # 资产端点 302 到存储 CDN; Invoke-WebRequest 跨域跳转时默认剥离 Authorization 头
    Invoke-WebRequest -Uri $asset.url -OutFile $name -Headers @{
        Authorization = "Bearer $env:GH_TOKEN"
        Accept        = "application/octet-stream"
    }
}

# latest.json 的 platforms 每个条目都须带 minisign 签名 (tauri-plugin-updater 解析要求),
# Bruce.zip 在本作业签名: 私钥只注入 release-windows 一处, tauri-cli 已由前序步骤安装。
$macSig = "$macZip.sig"
Remove-Item $macSig -ErrorAction SilentlyContinue
cargo tauri signer sign $macZip
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $macSig) -or -not (Get-Content $macSig -Raw).Trim()) {
    Write-Error "$macZip 签名失败或 $macSig 为空 (检查 TAURI_SIGNING_PRIVATE_KEY / _PASSWORD secret)"
    exit 1
}

$latestJson = "latest.json"
node scripts/generate-update-manifest.mjs `
    --mac-zip $macZip `
    --mac-sums SHA256SUMS `
    --mac-sig $macSig `
    --win-setup $setup.FullName `
    --win-sig $sigFile `
    --notes $notesFile `
    --tag $tag `
    --out $latestJson
# 原生命令非零退出不受 $ErrorActionPreference 约束, 必须显式检查
if ($LASTEXITCODE -ne 0) {
    Write-Error "latest.json 生成失败 (见上方 generate-update-manifest 输出)"
    exit 1
}

foreach ($name in @($setup.Name, $sumFile, "$($setup.Name).sig", $macSig, $latestJson)) {
    $stale = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($stale) {
        Write-Host "清理同名残留资产 $name (id=$($stale.id))"
        gh api --method DELETE "repos/$repo/releases/assets/$($stale.id)"
    }
}

gh api --method POST "$($uploadUrl)?name=$($setup.Name)" -H "Content-Type: application/octet-stream" --input "$($setup.FullName)"
gh api --method POST "$($uploadUrl)?name=$sumFile" -H "Content-Type: application/octet-stream" --input "$sumFile"
gh api --method POST "$($uploadUrl)?name=$($setup.Name).sig" -H "Content-Type: application/octet-stream" --input $sigFile
gh api --method POST "$($uploadUrl)?name=$macSig" -H "Content-Type: application/octet-stream" --input $macSig
gh api --method POST "$($uploadUrl)?name=$latestJson" -H "Content-Type: application/octet-stream" --input $latestJson

# 全量多端产物 (macOS + Windows) 上传完毕，正式将草稿发布为公开 Release
Write-Host "多端产物上传完毕，发布 Release $($release.id)"
gh api --method PATCH "repos/$repo/releases/$($release.id)" -F draft=false -F make_latest=true
