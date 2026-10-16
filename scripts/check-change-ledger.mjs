#!/usr/bin/env node
// 变更总账一致性门禁 (TD-011 定稿语义的可校验下限)。
//
// 校验 docs/devel/change/index.json 的下列不变式:
//   1. 每张卡的 topic 字段必须出现在对应 topics[].changes 中 (主卡归属下限);
//   2. topics 中不得出现无卡条目的孤儿编号;
//   3. 每个 topic 的 design_doc、每张卡的 file 路径都必须存在。
//
// 允许「数组 ⊋ 主卡归属集合」(跨文档多归属), 故不检查重复归属。

import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const indexPath = resolve(repoRoot, "docs/devel/change/index.json");
const ledger = JSON.parse(readFileSync(indexPath, "utf8"));

const problems = [];

// 1 + 2. 双向归属
for (const [id, card] of Object.entries(ledger.cards)) {
  const topic = ledger.topics[card.topic];
  if (!topic) {
    problems.push(`卡 ${id} 的 topic "${card.topic}" 在 topics 中不存在`);
    continue;
  }
  if (!topic.changes.includes(id)) {
    problems.push(`卡 ${id} 声明 topic=${card.topic}, 但未登记进该 topic 的 changes`);
  }
}
const listed = new Set(Object.values(ledger.topics).flatMap((topic) => topic.changes));
for (const id of listed) {
  if (!ledger.cards[id]) problems.push(`topics 中的 ${id} 没有对应卡条目`);
}

// 3. 路径存在性
for (const [name, topic] of Object.entries(ledger.topics)) {
  const doc = resolve(repoRoot, topic.design_doc);
  if (!existsSync(doc)) problems.push(`topic ${name} 的 design_doc 不存在: ${topic.design_doc}`);
}
for (const [id, card] of Object.entries(ledger.cards)) {
  if (!existsSync(resolve(repoRoot, card.file))) {
    problems.push(`卡 ${id} 的 file 路径不存在: ${card.file}`);
  }
}

if (problems.length > 0) {
  console.error("变更总账一致性校验失败:");
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}
console.log(
  `变更总账一致 (cards=${Object.keys(ledger.cards).length} topics=${Object.keys(ledger.topics).length})`,
);
