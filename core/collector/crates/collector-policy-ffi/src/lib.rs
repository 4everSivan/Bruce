//! 共享策略的 C ABI (T16, design/08 第二期): mac 以静态库链接后进程内调用。
//!
//! 只有两个函数: `bruce_policy_call` 收 policy-request-v1 字节、返回 policy-response-v1
//! 字节 (与 `collector_policy::handle_request` 同一入口, 校验与诊断语义一致);
//! `bruce_policy_free` 释放返回的缓冲区。错误一律以诊断信封返回, panic 不越过边界。

use std::panic::{catch_unwind, AssertUnwindSafe};

/// 序列化本身失败或越界 panic 时的兜底信封 (不依赖任何堆上状态)。
const PANIC_ENVELOPE: &str = r#"{"schemaVersion":1,"status":"error","operation":null,"result":null,"diagnostics":[{"code":"POLICY_INTERNAL_PANIC","message":"策略计算内部错误 (已捕获 panic)"}]}"#;

/// 处理一次策略请求, 返回 policy-response-v1 字节; 长度写入 `out_len`。
///
/// 返回的缓冲区必须且只能以同一长度交给 `bruce_policy_free` 释放一次。
/// `out_len` 为空时不分配, 返回空指针。
///
/// # Safety
///
/// `request` 为空或 `request_len` 为 0 时视为空请求; 否则必须指向至少 `request_len`
/// 字节、在调用期间有效的只读内存。`out_len` 为空或指向可写的 `usize`。
#[no_mangle]
pub unsafe extern "C" fn bruce_policy_call(
    request: *const u8,
    request_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    let input: &[u8] = if request.is_null() || request_len == 0 {
        &[]
    } else {
        // SAFETY: 调用方保证 request 指向 request_len 字节的有效只读内存。
        unsafe { std::slice::from_raw_parts(request, request_len) }
    };
    let output = catch_unwind(AssertUnwindSafe(|| {
        serde_json::to_vec(&collector_policy::handle_request(input))
            .unwrap_or_else(|_| PANIC_ENVELOPE.as_bytes().to_vec())
    }))
    .unwrap_or_else(|_| PANIC_ENVELOPE.as_bytes().to_vec());
    let output = output.into_boxed_slice();
    // SAFETY: 上文已确认 out_len 非空, 调用方保证其可写。
    unsafe { *out_len = output.len() };
    Box::into_raw(output).cast::<u8>()
}

/// 释放 `bruce_policy_call` 返回的缓冲区; 空指针时什么也不做。
///
/// # Safety
///
/// `buffer` 必须是 `bruce_policy_call` 返回且尚未释放的指针, `len` 为当时写入
/// `out_len` 的长度。
#[no_mangle]
pub unsafe extern "C" fn bruce_policy_free(buffer: *mut u8, len: usize) {
    if buffer.is_null() {
        return;
    }
    // SAFETY: buffer / len 来自 bruce_policy_call 中 Box<[u8]> 的 into_raw。
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer, len)) });
}
