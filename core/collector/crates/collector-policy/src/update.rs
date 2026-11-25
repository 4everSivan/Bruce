//! 软件更新的纯规则 (C263, design/08 SharedPolicyCore)。
//!
//! 两端共用一份判定: 宽松 SemVer 排序 (展示/跳过记录)、严格三段 SemVer
//! (清单合法性)、下载地址域名白名单与跳过恢复语义。不做网络 / 文件 I/O。
//!
//! 严格口径对齐 macOS `SemanticVersion` 与 Windows `software_update.rs`:
//! 可带 `v`/`V` 前缀, 恰好 3 段且每段非空纯数字; 预发布/构建后缀/缺段一律无效;
//! 下载地址仅允许 `https://github.com/...` (被污染的清单不得指向第三方主机)。

use std::cmp::Ordering;

/// 清单允许的下载主机 (与 mac `UpdateRelease.parse` 一致)。
pub const ALLOWED_DOWNLOAD_HOST: &str = "github.com";

/// 宽松三段版本解析 (排序用): 去掉 `v` 前缀, 每段取前导数字, 缺失/非数字按 0。
pub fn parse_semver(value: &str) -> (u64, u64, u64) {
    let parts: Vec<&str> = value.trim().trim_start_matches('v').split('.').collect();
    let pick = |index: usize| -> u64 {
        parts
            .get(index)
            .map(|part| {
                part.chars()
                    .take_while(|c| c.is_ascii_digit())
                    .collect::<String>()
                    .parse()
                    .unwrap_or(0)
            })
            .unwrap_or(0)
    };
    (pick(0), pick(1), pick(2))
}

/// 按宽松 SemVer 比较两个版本。
pub fn compare_semver(a: &str, b: &str) -> Ordering {
    parse_semver(a).cmp(&parse_semver(b))
}

/// 严格三段 SemVer: 清单版本不合法时整份清单无效, 不得进入跳过判定或下载。
pub fn is_strict_semver(value: &str) -> bool {
    let text = value.trim();
    let text = text
        .strip_prefix('v')
        .or_else(|| text.strip_prefix('V'))
        .unwrap_or(text);
    let parts: Vec<&str> = text.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
}

/// 清单下载地址白名单: 仅 `https://github.com/...`。
pub fn is_allowed_download_url(value: &str) -> bool {
    let Some((scheme, rest)) = value.split_once("://") else {
        return false;
    };
    if !scheme.eq_ignore_ascii_case("https") {
        return false;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    // 去掉 userinfo 与端口, 只比较主机名 (mac 使用 URL.host, 不含端口)。
    let host_port = authority.rsplit('@').next().unwrap_or("");
    let host = host_port.split(':').next().unwrap_or("");
    host.eq_ignore_ascii_case(ALLOWED_DOWNLOAD_HOST)
}

/// 跳过判定 (07 §4.2 R4): 跳过 vN 后, 远端仍是 vN → 不再提醒; 出现更新的版本 → 自动恢复。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipDecision {
    /// 未跳过或版本不同: 正常呈现, 且 offered > skipped 时应清除跳过记录。
    Offer { clear_skip: bool },
    /// offered == skipped: 维持「已跳过」呈现。
    Ignore,
}

pub fn skip_decision(offered: &str, skipped: Option<&str>) -> SkipDecision {
    match skipped {
        None => SkipDecision::Offer { clear_skip: false },
        Some(skipped) if compare_semver(offered, skipped) == Ordering::Equal => {
            SkipDecision::Ignore
        }
        Some(skipped) => SkipDecision::Offer {
            clear_skip: compare_semver(offered, skipped) == Ordering::Greater,
        },
    }
}

/// 本地版本追平或超过跳过版本时应清除跳过记录 (07 §4.2 R4)。
pub fn should_clear_skipped_on_catchup(local_version: &str, skipped: Option<&str>) -> bool {
    match skipped {
        Some(skipped) => compare_semver(local_version, skipped) != Ordering::Less,
        None => false,
    }
}

/// 清单元信息是否可进入下载/跳过判定: 版本严格合法且下载地址在白名单内。
pub fn is_manifest_trustworthy(version: &str, download_url: &str) -> bool {
    is_strict_semver(version) && is_allowed_download_url(download_url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lenient_semver_orders_numeric_segments() {
        assert_eq!(compare_semver("0.13.0", "0.12.2"), Ordering::Greater);
        assert_eq!(compare_semver("0.12.2", "0.12.2"), Ordering::Equal);
        assert_eq!(compare_semver("v0.12.2", "0.12.2"), Ordering::Equal);
        assert_eq!(compare_semver("1.0.0", "0.99.99"), Ordering::Greater);
        assert_eq!(compare_semver("0.12.10", "0.12.9"), Ordering::Greater);
    }

    #[test]
    fn strict_semver_rejects_prerelease_and_short_forms() {
        for ok in ["1.2.3", "v1.2.3", "V10.0.0", "0.0.0"] {
            assert!(is_strict_semver(ok), "应接受 {ok}");
        }
        for bad in [
            "",
            "1.2",
            "1.2.3.4",
            "1.2.3-beta",
            "1.2.3+build",
            "1..3",
            "1.2.x",
            "v",
        ] {
            assert!(!is_strict_semver(bad), "应拒绝 {bad}");
        }
    }

    #[test]
    fn download_url_must_be_github_https() {
        for ok in [
            "https://github.com/4everSivan/Bruce/releases/download/v1/x.exe",
            "HTTPS://GitHub.com/a/b",
            "https://github.com:443/a",
        ] {
            assert!(is_allowed_download_url(ok), "应接受 {ok}");
        }
        for bad in [
            "http://github.com/a",
            "https://evil.com/github.com/a",
            "https://github.com.evil.com/a",
            "https://github.com@evil.com/a",
            "github.com/a",
            "",
        ] {
            assert!(!is_allowed_download_url(bad), "应拒绝 {bad}");
        }
    }

    #[test]
    fn skip_decision_restores_on_newer_offer() {
        assert_eq!(
            skip_decision("0.13.0", None),
            SkipDecision::Offer { clear_skip: false }
        );
        assert_eq!(
            skip_decision("0.13.0", Some("0.13.0")),
            SkipDecision::Ignore
        );
        assert_eq!(
            skip_decision("0.14.0", Some("0.13.0")),
            SkipDecision::Offer { clear_skip: true }
        );
        assert!(should_clear_skipped_on_catchup("0.14.0", Some("0.13.0")));
        assert!(!should_clear_skipped_on_catchup("0.12.0", Some("0.13.0")));
        assert!(!should_clear_skipped_on_catchup("0.13.0", None));
    }

    #[test]
    fn manifest_trust_requires_both_rules() {
        assert!(is_manifest_trustworthy(
            "1.2.3",
            "https://github.com/a/b/releases/download/v1/x"
        ));
        assert!(!is_manifest_trustworthy(
            "1.2.3-beta",
            "https://github.com/x"
        ));
        assert!(!is_manifest_trustworthy("1.2.3", "http://github.com/x"));
    }
}
