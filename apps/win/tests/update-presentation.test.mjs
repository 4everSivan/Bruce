// 软件更新表现层双端对拍 (T11, 07-软件更新 §4.2 R3/R4)。
// 以 tests/fixtures/update-copy-parity/cases.json 为唯一契约逐例执行
// apps/win/src/update-presentation.js (纯函数, vm 沙箱加载), 与 mac SoftwareUpdateHarness
// 读同一份 fixture —— 期望值由设计与 demo 手写, 不由实现反推。
// 时间用例刻意依赖 ISO 字符串民事日解析 (不经宿主时区), 故在任意 CI 时区结果一致。

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");
const cases = JSON.parse(readFileSync(join(repoRoot, "tests/fixtures/update-copy-parity/cases.json"), "utf8"));

const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(
  readFileSync(join(repoRoot, "apps/win/src/update-presentation.js"), "utf8"),
  sandbox,
  { filename: "update-presentation.js" },
);
const P = sandbox.window.BruceUpdatePresentation;

test("表现层模块已导出", () => {
  assert.ok(P, "window.BruceUpdatePresentation 未导出");
});

test("行文案与共享 fixture 逐字一致", () => {
  for (const [key, expected] of Object.entries(cases.rows)) {
    assert.equal(P.copy[key], expected, `copy.${key} 漂移`);
  }
});

test("当前版本行: release 构建与 dev 降级", () => {
  for (const c of cases.currentVersion) {
    const view = P.currentVersion(c.localVersion);
    assert.equal(view.value, c.expectedValue, `${c.name} value`);
    // C142: 频道副标题已移除, 表现层不得再现 subtitle 字段.
    assert.equal(view.subtitle, undefined, `${c.name} 不应再有频道副标题`);
  }
});

test("上次检查副标题: 从未/同日/跨天", () => {
  for (const c of cases.lastCheck) {
    assert.equal(P.lastCheckSubtitle(c.at, cases.now), c.expected, `${c.name} (期望按 fixture 时区 ${cases.timeZone})`);
  }
});

test("8 态状态区与角标/按钮可用性逐例对拍", () => {
  assert.ok(cases.stages.length >= 18, `用例数异常: ${cases.stages.length}`);
  for (const c of cases.stages) {
    const ctx = {
      release: c.release || cases.release,
      localVersion: c.localVersion !== undefined ? c.localVersion : cases.localVersion,
      canSelfInstall: c.canSelfInstall !== undefined ? c.canSelfInstall : true,
      now: cases.now,
    };
    const view = P.stageView(c.phase, ctx);
    const flags = P.stageFlags(c.phase);
    for (const [key, expected] of Object.entries(c.expected)) {
      let actual = view[key];
      if (key === "actions") {
        // fixture 记标题序列; 实现返回 {key,title,role}, 额外校验标题在动作表内。
        // vm 沙箱数组与宿主 realm 原型不同 (deepStrictEqual 比原型), 故用宿主 Array.from 重建。
        assert.deepEqual(Array.from(actual, a => a.title), expected, `${c.name}.actions`);
        for (const item of actual) assert.ok(["primary", "plain", "link"].includes(item.role), `${c.name} 动作角色非法`);
        continue;
      }
      if (key === "fraction") continue; // percent 已覆盖 (fixture 字段名)
      if (key === "statusLine") continue; // 状态行由 failureStatusLine 单独覆盖 (见下)
      if (key === "percent") { assert.equal(Math.floor((view.fraction ?? 0) * 100), expected, `${c.name}.percent`); continue; }
      assert.deepEqual(actual, expected, `${c.name}.${key}`);
    }
    assert.equal(flags.navBadge, c.navBadge, `${c.name}.navBadge`);
    assert.equal(flags.checkEnabled, c.checkEnabled, `${c.name}.checkEnabled`);
  }
});

test("失败分类与状态行: 双端共享子集", () => {
  for (const c of cases.stages.filter(s => s.expected.statusLine)) {
    assert.equal(P.failureStatusLine(c.phase), c.expected.statusLine, `${c.name}.statusLine`);
  }
  const sharedInstall = cases.installFailures.find(x => x.kind === "downloadFailed");
  assert.ok(sharedInstall, "fixture 缺 downloadFailed");
  assert.equal(P.installFailureStatusLine("downloadFailed"), sharedInstall.statusLine);
});
