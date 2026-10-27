// 共享策略 Rust 静态库的 C ABI (T16, design/08 第二期)。
// 实现: core/collector/crates/collector-policy-ffi; 由 scripts/runtime-manifest.zsh 的
// Bruce_build_policy_ffi 构建到 local/build/policy-ffi/libbruce_policy.a。
// 请求 / 响应为 policy-request-v1 / policy-response-v1 JSON 字节 (core/collector/schemas)。

#ifndef BRUCE_POLICY_H
#define BRUCE_POLICY_H

#include <stddef.h>
#include <stdint.h>

// 处理一次策略请求, 返回响应字节并把长度写入 out_len; out_len 为空时返回 NULL。
// 返回的缓冲区必须以同一长度交给 bruce_policy_free 释放一次。
uint8_t *bruce_policy_call(const uint8_t *request, size_t request_len, size_t *out_len);

// 释放 bruce_policy_call 返回的缓冲区; NULL 时无操作。
void bruce_policy_free(uint8_t *buffer, size_t len);

#endif
