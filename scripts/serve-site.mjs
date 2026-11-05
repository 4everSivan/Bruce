#!/usr/bin/env node
// 官网本地预览服务（T27）：只服务构建产物 `local/dist/site/`，不服务源码目录。
//
// 用法：node scripts/build-site.mjs && node scripts/serve-site.mjs [端口]
// 默认端口 4311（与历史预览地址一致）。零依赖，只用 node 内置模块。

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const root = resolve(repoRoot, "local", "dist", "site");
const port = Number(process.argv[2] || process.env.PORT || 4311);

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".woff2": "font/woff2",
  ".ico": "image/x-icon",
};

try {
  await stat(join(root, "index.html"));
} catch {
  console.error(`缺少构建产物：${root}/index.html\n先运行：node scripts/build-site.mjs`);
  process.exit(1);
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  const pathname = decodeURIComponent(url.pathname);
  let filePath = resolve(root, "." + normalize(pathname));

  if (!filePath.startsWith(root)) {
    response.writeHead(403).end("forbidden");
    return;
  }

  try {
    const info = await stat(filePath);
    if (info.isDirectory()) filePath = join(filePath, "index.html");
    const body = await readFile(filePath);
    response.writeHead(200, {
      "content-type": MIME[extname(filePath)] || "application/octet-stream",
      "cache-control": "no-store",
    });
    response.end(body);
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" }).end("404");
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`site preview: http://127.0.0.1:${port}/  (root: local/dist/site)`);
});
