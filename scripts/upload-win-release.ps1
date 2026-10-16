# Bruce Windows 发布资产上传脚本 (T04 / C036)。
# 由 .github/workflows/ci.yml 的 release-windows 作业调用 (tag 触发): 把 NSIS 安装包与
# SHA256 校验和上传到 mac 侧 release 作业建好的同 tag 草稿 Release, 随后发布该草稿。
#
# 纪律 (C036):
#   1. release 列表必须分页 (--paginate --slurp): 该端点默认 30 条/页, release 总数超过
#      30 后目标草稿不在首页, 查找落空会让上传直接失败;
#   2. 重跑幂等: 同名资产已存在时 POST 返回 422 already_exists (仅重试本作业而不重跑
#      release 作业时, 草稿里往往已有上一轮资产), 上传前先删同名残留;
#   3. 本脚本由 verify-windows 作业的 AST 解析步骤做语法门禁, 非 tag 场景也能被验证。
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

foreach ($name in @($setup.Name, $sumFile)) {
    $stale = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($stale) {
        Write-Host "清理同名残留资产 $name (id=$($stale.id))"
        gh api --method DELETE "repos/$repo/releases/assets/$($stale.id)"
    }
}

gh api --method POST "$($uploadUrl)?name=$($setup.Name)" -H "Content-Type: application/octet-stream" --input "$($setup.FullName)"
gh api --method POST "$($uploadUrl)?name=$sumFile" -H "Content-Type: application/octet-stream" --input "$sumFile"

# 全量多端产物 (macOS + Windows) 上传完毕，正式将草稿发布为公开 Release
Write-Host "多端产物上传完毕，发布 Release $($release.id)"
gh api --method PATCH "repos/$repo/releases/$($release.id)" -F draft=false -F make_latest=true
