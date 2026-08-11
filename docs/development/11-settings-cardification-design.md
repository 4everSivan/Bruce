# 设置页卡片化与版本号显示 — 设计文档

- 日期: 2026-08-11
- 范围: macOS 设置窗口 (`SettingsView`) 视觉层 + 版本来源统一
- 影响面: `macos/MdddApp/Sources/MdddApp/SettingsView.swift`, 打包脚本, 新增 1 个容器组件 + 版本读取

## 背景

用户反馈设置窗口使用系统默认 grouped Form 观感, 希望增强为独立卡片, 并在设置页显示应用版本号。

## 目标 (成功标准)

1. 设置页 6 个分区呈现为独立卡片: 圆角 12px + 细边框 + 浅阴影, 分区标题带色条与加粗。
2. 卡片样式**不跟随主题** (classic / 液态玻璃共用同一套外观)。
3. 「通用」分区底部显示版本号 `0.3.0` (仅版本, 不含构建号)。
4. 版本号单一事实源: 打包脚本从 `pyproject.toml` 读取, 不再硬编码。
5. 不动业务逻辑、数据流、PanelViewModel 映射与 Collector。

## 现状

- `SettingsView.body` 用 `Form` + `.formStyle(.grouped)`, 6 个分区 (`generalSection` / `agentUsageCard` / `subscriptionSection` / `consentSection` / `dataSection` / `diagnosticsSection`), 每个分区是独立 `Section`。
- 版本号仅在诊断导出 (`Diagnostics`) 中经 `CFBundleShortVersionString` 读取, 设置页无展示。
- `scripts/build-test-app.sh` 写死 `CFBundleShortVersionString = 0.1.0`。

## 设计

### 1. 卡片化 (统一样式, 不跟随主题)

**新增容器组件 `SettingsCard`** (置于 `macos/MdddApp/Sources/MdddApp/Settings/` 下, 与其他设置分区组件同目录):

```swift
/// 设置分区卡片容器: 圆角 12 + 细边框 + 浅阴影, 统一不随主题.
struct SettingsCard<Content: View>: View {
    var body: some View {
        content
            .padding(...)
            .background(...)   // 卡片底色
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(...))
            .shadow(...)
    }
}
```

- 圆角 `12`, 细边框 `1pt` (低对比色), 浅阴影 (仅 classic 明暗两套中性值)。
- 不读取 `ResolvedTheme`/`interfaceStyle`, 保证两主题同款。
- 6 个分区内容 (Section 的 content) 用 `SettingsCard` 包裹; 保留 `Form` + `.formStyle(.grouped)` 结构 (分区语义、分组标题位置不变)。

**分区标题色条**:

| 分区 | 色条色 |
|---|---|
| 通用 | `#0a84ff` (蓝) |
| Agent 用量 | `#30d158` (绿) |
| 订阅额度 | `#ff9f0a` (橙) |
| 统一授权 | `#bf5af2` (紫) |
| 数据 | `#8e8e93` (灰) |
| 诊断 | `#40c8e0` (青) |

标题呈现: 色条 (宽 4pt 圆角条) + 加粗文字 (`fontWeight(.bold)`), 行高与既有 Section 标题一致。

内容行 (LabeledContent / 按钮行等) 保持现有分割线 (`Divider`) 与布局, 仅容器外观变化。

### 2. 版本号显示

「通用」分区 (`generalSection`) 末尾新增:

```swift
LabeledContent("版本", value: AppVersion.current)
```

**新增 `AppVersion`** (纯逻辑, 可测试):

```swift
/// 应用版本号: 只读 Bundle 短版本字符串, 缺失时回落占位.
enum AppVersion {
    /// 测试可注入 bundle 值.
    static func current(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
```

- 仅显示 `0.3.0`, 不含构建号。
- 不写 `about` 子视图, 不加新分区。

### 3. 版本单一事实源 (打包脚本)

`scripts/build-test-app.sh` 当前写死 `0.1.0`:

```bash
plutil -insert CFBundleShortVersionString -string "0.1.0" "$MDDD_INFO_PLIST"
```

改为从 `pyproject.toml` 读取:

```bash
MDDD_VERSION=$(python3 -c 'import re; print(re.search(r"^version\s*=\s*\"([^\"]+)\"", open("pyproject.toml").read(), re.M).group(1))')
plutil -insert CFBundleShortVersionString -string "$MDDD_VERSION" "$MDDD_INFO_PLIST"
```

- 用正则读取 `version` 字段, 兼容 Python 3.9 (项目最低要求), 不引入 `tomli` 依赖。
- 读取失败 (正则不匹配) → 脚本报错退出, 不产出版本错误的包。
- `build-release-app.sh` 已有 `MDDD_VERSION` 变量 (来自 tag), 不重复读取, 保持现状。

### 4. 错误处理与降级

- `AppVersion.current` 读不到版本 → 显示 `"unknown"` (不崩溃, 不阻断设置页)。
- 打包脚本正则读 `pyproject.toml` 失败 → 脚本报错退出 (不产出版本错误的包), 与现有 `set -euo pipefail` 一致。

## 测试

1. **AppVersion 单元测试**: 注入 mock bundle (或直接测读取逻辑) — 有值返回、无值回落 `"unknown"`。
2. **打包脚本**: 现有 `verify-local.sh` 不测打包; 本改动仅手工验证 (`build-test-app.sh` 输出 Info.plist 版本 = `0.3.0`)。
3. **设置页视觉**: 手工验收 (卡片外观、色条、版本行)。
4. 不新增/修改 PanelViewModel、Collector 相关测试。

## 不做的事 (YAGNI)

- 不跟随主题 (液态玻璃下不同观感) — 明确排除。
- 不显示构建号、不做「关于」窗口。
- 不改分区顺序/结构/内容, 只改观感。
- 不改 `build-release-app.sh` 的版本来源 (已从 tag 派生)。
