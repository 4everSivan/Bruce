#!/usr/bin/env node
// 变更总账一致性门禁 (TD-011 定稿语义的可校验下限)。
//
// 校验 docs/devel/change/index.json 的下列不变式:
//   1. 每张卡的 topic 字段必须出现在对应 topics[].changes 中 (主卡归属下限);
//   2. topics 中不得出现无卡条目的孤儿编号;
//   3. 每个 topic 的 design_doc、每张卡的 file 路径都必须存在。
//
// 归档卡登记迁入归档批次总账 docs/archive/<version>/index.json (adflow-archive-batch-v1, C226) 后,
// 每个批次总账的 cards 同样遵守 1–3 (topic 须在现行 topics 登记, 以沿用其 design_doc),
// 且同一卡号不得在现行总账与批次总账之间重复登记。
//
// 允许「数组 ⊋ 主卡归属集合」(跨文档多归属), 故不检查重复归属。

import { existsSync, readdirSync, readFileSync } from "node:fs";
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

// 4. 归档批次总账: 同样的归属与路径不变式, 外加跨总账重号
const archiveRoot = resolve(repoRoot, "docs/archive");
const registeredIn = new Map(Object.keys(ledger.cards).map((id) => [id, "docs/devel/change/index.json"]));
let batchLedgers = 0;
let batchCards = 0;
const batches = readdirSync(archiveRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && existsSync(resolve(archiveRoot, entry.name, "index.json")))
  .map((entry) => `docs/archive/${entry.name}/index.json`)
  .sort();
for (const rel of batches) {
  const batch = JSON.parse(readFileSync(resolve(repoRoot, rel), "utf8"));
  if (batch.$schema !== "adflow-archive-batch-v1") continue;
  batchLedgers += 1;
  const cards = batch.cards || {};
  const topics = batch.topics || {};
  for (const [id, card] of Object.entries(cards)) {
    batchCards += 1;
    if (registeredIn.has(id)) problems.push(`卡 ${id} 同时登记在 ${registeredIn.get(id)} 与 ${rel}`);
    else registeredIn.set(id, rel);
    if (!ledger.topics[card.topic]) {
      problems.push(`${rel}: 卡 ${id} 的 topic "${card.topic}" 未在现行 topics 中登记`);
    } else if (!(topics[card.topic]?.changes || []).includes(id)) {
      problems.push(`${rel}: 卡 ${id} 声明 topic=${card.topic}, 但未登记进本批次该 topic 的 changes`);
    }
    if (!existsSync(resolve(repoRoot, card.file))) problems.push(`${rel}: 卡 ${id} 的 file 路径不存在: ${card.file}`);
  }
  // 批次 topics 两轨共用, 只核对列有变更卡 (changes) 的主题; 任务轨主题由任务总账登记。
  for (const [name, topic] of Object.entries(topics)) {
    const ids = topic.changes || [];
    if (ids.length > 0 && !ledger.topics[name]) problems.push(`${rel}: topic ${name} 未在现行 topics 中登记`);
    for (const id of ids) {
      if (!cards[id]) problems.push(`${rel}: topics 中的 ${id} 没有本批次卡条目`);
    }
  }
}

if (problems.length > 0) {
  console.error("变更总账一致性校验失败:");
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}
console.log(
  `变更总账一致 (cards=${Object.keys(ledger.cards).length} topics=${Object.keys(ledger.topics).length}` +
    ` 批次总账=${batchLedgers} 归档 cards=${batchCards})`,
);
