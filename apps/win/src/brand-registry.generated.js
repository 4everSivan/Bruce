// 本文件由 scripts/gen-brand-registry.mjs 生成, 请勿手改 (C263)。
// 修改 config/brand-registry.json 后运行 node scripts/gen-brand-registry.mjs;
// verify-local 以 --check 拦截漂移。
(function () {
  const data = {
    schemaVersion: 1,
    updatedAt: "2026-11-24",
    nothingRamp: {
      dark: ["#8CCB98", "#5FAF6E", "#4A9E5C", "#35854A", "#2A6B3C"],
      light: ["#946A08", "#B8860B", "#D4A843", "#E3BE6B", "#F0D69A"],
    },
    agentTiers: {
      "antigravity": 3,
      "claude-code": 1,
      "codebuddy": 2,
      "codex": 2,
      "dsh": 1,
      "grok": 2,
      "kimi-code-cli": 0,
      "kimi-work": 4,
      "opencode": 4,
      "pi": 4,
      "zcode": 3,
    },
  };
  // UTF-8 字节序列: 与 Rust as_bytes()/Swift utf8 逐字节一致。
  data.utf8Bytes = function utf8Bytes(text) {
    const bytes = [];
    for (const char of String(text)) {
      const code = char.codePointAt(0);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        bytes.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      }
    }
    return bytes;
  };
  // FNV-1a 64 (offset 0xcbf29ce484222325, prime 0x100000001b3): 与 Rust/Swift 端同法。
  // BigInt 保证 64 位不回绕到 32 位 (C263 修正旧 UTF-16 32-bit 实现)。
  data.fnv1a64 = function fnv1a64(text) {
    let hash = 0xcbf29ce484222325n;
    for (const byte of data.utf8Bytes(text)) {
      hash ^= BigInt(byte);
      hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
    }
    return hash;
  };
  window.BRUCE_BRAND_REGISTRY = data;
})();
