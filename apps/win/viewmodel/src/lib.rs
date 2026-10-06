#![deny(unsafe_code)]

//! Windows 面板视图模型层 —— mac 端 `BruceAppCore` 的 Rust 对齐实现。
//!
//! 纯函数层: artifact (collector-domain 契约) 输入 → 可序列化视图模型输出,
//! 不含任何渲染与 I/O 副作用。与 mac Swift 端的行为一致性由共享 artifact
//! fixture 的双端对拍测试锁定 (设计文档 `05-Windows平台适配.md` §5.3)。

pub mod color;
pub mod format;
pub mod models;
pub mod usage;
