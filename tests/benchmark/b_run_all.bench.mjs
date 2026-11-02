// @managed-by: test-anything
// @module: global
// @type: benchmark_runner
// @cases_doc: tests/docs/cases/b_*_cases.md
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { run as runPricingCatalog, meta as metaPricingCatalog } from "./b_pricing_catalog.bench.mjs";
import { run as runPricingPresentation, meta as metaPricingPresentation } from "./b_pricing_presentation.bench.mjs";
import { run as runArtifactContract, meta as metaArtifactContract } from "./b_artifact_contract.bench.mjs";
import { run as runQuotaPolicyContract, meta as metaQuotaPolicyContract } from "./b_quota_policy_contract.bench.mjs";
import { run as runProviderBrand, meta as metaProviderBrand } from "./b_provider_brand.bench.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const tmpDir = join(repoRoot, "tests/tmp");

const suites = [
  { meta: metaPricingCatalog, run: runPricingCatalog },
  { meta: metaPricingPresentation, run: runPricingPresentation },
  { meta: metaArtifactContract, run: runArtifactContract },
  { meta: metaQuotaPolicyContract, run: runQuotaPolicyContract },
  { meta: metaProviderBrand, run: runProviderBrand },
];

const started = performance.now();
const metrics = [];
for (const suite of suites) {
  for (const result of suite.run()) metrics.push(result);
}
const durationMs = performance.now() - started;

mkdirSync(tmpDir, { recursive: true });
const output = {
  run_id: new Date().toISOString().replace(/[-:T]/g, "").slice(0, 15),
  executed_at: new Date().toISOString(),
  duration_ms: Number(durationMs.toFixed(3)),
  total: metrics.length,
  metrics,
};
writeFileSync(join(tmpDir, "bench_latest.json"), `${JSON.stringify(output, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
