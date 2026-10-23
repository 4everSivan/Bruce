//! StepFun (Step Plan) 网页登录自动捕获与远程校验 (C086 / 设计规则 24)。
//!
//! 对齐 mac `StepFunWebLoginView.swift` (54–560):
//! - **站点**: 国内站 `platform.stepfun.com/step-plan` (域关键字 `stepfun.com`),
//!   国际站 `platform.stepfun.ai/plan-subscribe` (域关键字 `stepfun.ai`);
//! - **过滤**: 自动捕获仅在当前页面 URL 属目标站点域名且不含 `_not-found` 时触发;
//!   取名称为 `Oasis-Token`、cookie 域含目标关键字、去首尾空白后长度 > 10 的值;
//! - **远程校验**: POST `/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit`,
//!   携带 `Oasis-Token` / `Oasis-appID` (国内 10300, 国际且令牌 app_id==20700 时 20700) /
//!   `Oasis-Platform: web` / `Oasis-Language` (`zh-CN` | `en-US`) / `Oasis-Webid` (JWT `device_id`),
//!   仅 HTTP 200 视为有效并持久化绑定;
//! - **清缓存**: 筛出当前站点域关键字下的全部 cookie 供 WebView2 删除并重载订阅页。
//!
//! 线程约束: Tauri 的 `cookies()` / `cookies_for_url()` 在 Windows 同步 command 中会死锁
//! (WebView2 STA 重入问题, wry#583), 调用方必须位于 `async` command 或独立工作线程。

use base64::{
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD},
    Engine,
};
use serde_json::{json, Value};
use std::time::Duration;

/// 内置 WebView2 登录窗口与远程校验共用的桌面 Chrome User-Agent (规则 24)。
pub const STEPFUN_DESKTOP_CHROME_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) \
AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

const DOMESTIC_PLAN_URL: &str = "https://platform.stepfun.com/step-plan";
const GLOBAL_PLAN_URL: &str = "https://platform.stepfun.ai/plan-subscribe";
const DOMESTIC_HOME_URL: &str = "https://platform.stepfun.com";
const GLOBAL_HOME_URL: &str = "https://platform.stepfun.ai";
const DOMESTIC_RATE_LIMIT_URL: &str =
    "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit";
const GLOBAL_RATE_LIMIT_URL: &str =
    "https://platform.stepfun.ai/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit";

/// StepFun 站点类型 (对齐 mac `StepFunSite`)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepFunSite {
    Domestic,
    Global,
}

impl StepFunSite {
    /// 解析前端传入的站点标识 (`"domestic"` / `"global"`)。
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim() {
            "domestic" => Some(Self::Domestic),
            "global" => Some(Self::Global),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Domestic => "domestic",
            Self::Global => "global",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Domestic => "🇨🇳 国内站",
            Self::Global => "🌐 国际站",
        }
    }

    pub fn domain_keyword(self) -> &'static str {
        match self {
            Self::Domestic => "stepfun.com",
            Self::Global => "stepfun.ai",
        }
    }

    /// 订阅/额度管理页面 (国内 `/step-plan`, 国际 `/plan-subscribe`)。
    pub fn base_url(self) -> &'static str {
        match self {
            Self::Domestic => DOMESTIC_PLAN_URL,
            Self::Global => GLOBAL_PLAN_URL,
        }
    }

    /// 平台官网首页。
    pub fn home_url(self) -> &'static str {
        match self {
            Self::Domestic => DOMESTIC_HOME_URL,
            Self::Global => GLOBAL_HOME_URL,
        }
    }

    /// Step Plan 速率限制查询端点 (用于捕获后远程校验)。
    pub fn rate_limit_url(self) -> &'static str {
        match self {
            Self::Domestic => DOMESTIC_RATE_LIMIT_URL,
            Self::Global => GLOBAL_RATE_LIMIT_URL,
        }
    }

    pub fn language(self) -> &'static str {
        match self {
            Self::Domestic => "zh-CN",
            Self::Global => "en-US",
        }
    }
}

/// 平台无关的 Cookie 摘要 (解耦 Tauri `Cookie<'static>` 以便纯函数单测)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CookieCandidate {
    pub name: String,
    pub value: String,
    pub domain: String,
}

/// 自动捕获的页面 URL 门禁 (对齐 `StepFunWebLoginView.checkAutoCapture`)。
///
/// 仅当当前 Web 页面属目标站点域名且非 `_not-found` 错误页时才允许自动捕获;
/// 手动点击「我已登录，立即绑定」不受当前页面路径限制。
pub fn page_allows_auto_capture(current_url: &str, site: StepFunSite) -> bool {
    let trimmed = current_url.trim();
    if trimmed.is_empty() || trimmed.contains("_not-found") {
        return false;
    }
    trimmed.to_ascii_lowercase().contains(site.domain_keyword())
}

/// 从 Cookie 列表中提取目标站点的有效 `Oasis-Token` (对齐 `extractTokenAndSubmit`)。
///
/// 过滤规则:
/// 1. 名称严格为 `Oasis-Token`;
/// 2. Cookie 域名 (转小写) 包含目标站点关键字 (`stepfun.com` 或 `stepfun.ai`);
/// 3. 值去首尾空白后非空且字符数 `> 10`。
pub fn select_oasis_token(cookies: &[CookieCandidate], site: StepFunSite) -> Option<String> {
    let keyword = site.domain_keyword();
    for cookie in cookies {
        if cookie.name != "Oasis-Token" {
            continue;
        }
        if !cookie.domain.to_ascii_lowercase().contains(keyword) {
            continue;
        }
        let val = cookie.value.trim();
        if val.chars().count() > 10 {
            return Some(val.to_owned());
        }
    }
    None
}

/// 判断单条 Cookie 是否属于目标站点 (供「清除登录缓存」按域删除)。
pub fn cookie_matches_site(domain: &str, site: StepFunSite) -> bool {
    domain.to_ascii_lowercase().contains(site.domain_keyword())
}

/// 筛出清除登录缓存时应删除的 Cookie 索引或条目。
pub fn cookies_to_clear(cookies: &[CookieCandidate], site: StepFunSite) -> Vec<CookieCandidate> {
    cookies
        .iter()
        .filter(|cookie| cookie_matches_site(&cookie.domain, site))
        .cloned()
        .collect()
}

fn decode_jwt_payload(token: &str) -> Option<Value> {
    let target_jwt = token.split("...").last().unwrap_or(token);
    let mut parts = target_jwt.split('.');
    let _header = parts.next()?;
    let payload_b64 = parts.next()?;
    let bytes = URL_SAFE_NO_PAD
        .decode(payload_b64)
        .or_else(|_| URL_SAFE.decode(payload_b64))
        .or_else(|_| STANDARD_NO_PAD.decode(payload_b64))
        .or_else(|_| STANDARD.decode(payload_b64))
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// 从 StepFun `Oasis-Token` 的末段 JWT 载荷提取 `device_id` (对齐 `StepFunRemoteVerifier.extractDeviceID`)。
pub fn extract_device_id(token: &str) -> Option<String> {
    let payload = decode_jwt_payload(token)?;
    payload
        .get("device_id")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// 从 StepFun `Oasis-Token` 的末段 JWT 载荷提取 `app_id` (国内 10300, 国际 20700)。
pub fn extract_app_id(token: &str) -> Option<u32> {
    let payload = decode_jwt_payload(token)?;
    if let Some(id) = payload.get("app_id").and_then(Value::as_u64) {
        return u32::try_from(id).ok();
    }
    payload
        .get("app_id")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<u32>().ok())
}

/// 判断令牌是否属国际站 (`app_id == 20700`)。
pub fn is_global_token(token: &str) -> bool {
    extract_app_id(token) == Some(20700)
}

/// 远程校验请求描述 (供单测断言端点与请求头, 以及传输层发包)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepFunVerifyRequest {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

/// 组装 `QueryStepPlanRateLimit` 远程校验请求 (对齐 `StepFunRemoteVerifier.verify`)。
pub fn build_verify_request(token: &str, site: Option<StepFunSite>) -> StepFunVerifyRequest {
    let is_global = site == Some(StepFunSite::Global) || is_global_token(token);
    let target_site = if is_global {
        StepFunSite::Global
    } else {
        StepFunSite::Domestic
    };
    let origin = target_site.home_url();
    let referer = format!("{origin}/");
    let app_id = if is_global && extract_app_id(token) == Some(20700) {
        "20700"
    } else {
        "10300"
    };

    let mut headers = vec![
        ("Content-Type".to_owned(), "application/json".to_owned()),
        ("Accept".to_owned(), "application/json".to_owned()),
        ("Origin".to_owned(), origin.to_owned()),
        ("Referer".to_owned(), referer),
        (
            "User-Agent".to_owned(),
            STEPFUN_DESKTOP_CHROME_UA.to_owned(),
        ),
        ("Oasis-Token".to_owned(), token.to_owned()),
        ("Oasis-appID".to_owned(), app_id.to_owned()),
        ("Oasis-Platform".to_owned(), "web".to_owned()),
        (
            "Oasis-Language".to_owned(),
            target_site.language().to_owned(),
        ),
        ("Cookie".to_owned(), format!("Oasis-Token={token}")),
    ];
    if let Some(did) = extract_device_id(token) {
        headers.push(("Oasis-Webid".to_owned(), did));
    }

    StepFunVerifyRequest {
        url: target_site.rate_limit_url().to_owned(),
        headers,
        body: "{}".to_owned(),
    }
}

/// 可注入的远程校验 HTTP 传输边界 (测试用 mock 替身, 生产走 `UreqStepFunTransport`)。
pub trait StepFunRemoteTransport: Send + Sync {
    fn post_status(&self, request: &StepFunVerifyRequest) -> Result<u16, String>;
}

/// 默认 HTTP 传输: 8s 超时、禁止重定向 (防止 `Oasis-Token` 随重定向外泄)。
pub struct UreqStepFunTransport;

impl StepFunRemoteTransport for UreqStepFunTransport {
    fn post_status(&self, request: &StepFunVerifyRequest) -> Result<u16, String> {
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(8))
            .redirects(0)
            .build();
        let mut req = agent.post(&request.url);
        for (name, value) in &request.headers {
            req = req.set(name, value);
        }
        match req.send_string(&request.body) {
            Ok(resp) => Ok(resp.status()),
            Err(ureq::Error::Status(code, _)) => Ok(code),
            Err(_) => Err("网络不可达".to_owned()),
        }
    }
}

/// 使用指定传输边界校验 `Oasis-Token` 是否被远端接受 (仅 HTTP 200 为 `true`)。
pub fn verify_remote_with(
    token: &str,
    site: Option<StepFunSite>,
    transport: &dyn StepFunRemoteTransport,
) -> bool {
    let request = build_verify_request(token, site);
    matches!(transport.post_status(&request), Ok(200))
}

/// 生产入口: 发起一次真实 `QueryStepPlanRateLimit` POST 校验。
pub fn verify_remote(token: &str, site: Option<StepFunSite>) -> bool {
    verify_remote_with(token, site, &UreqStepFunTransport)
}

/// 与前端 `credentialAccountId("stepfun", { token })` 同构的 DJB2 账号 ID 派生 (C093):
/// 同一 `token` 无论经手粘还是网页登录捕获都落到同一账号槽位, 重新绑定即 upsert。
pub fn stepfun_account_id(token: &str) -> String {
    let identity = json!({ "token": token });
    let text = format!("stepfun:{identity}");
    let mut hash: u32 = 5381;
    for unit in text.encode_utf16() {
        hash = hash.wrapping_mul(33) ^ u32::from(unit);
    }
    format!("stepfun-{hash:08x}")
}

/// 组装持久化至 `stepfunQuotaAccounts` 的账号载荷。
pub fn stepfun_account_payload(token: &str, site: StepFunSite, account_id: &str) -> Value {
    let suffix = account_id.rsplit('-').next().unwrap_or(account_id);
    json!({
        "token": token,
        "site": site.as_str(),
        "is_global": site == StepFunSite::Global,
        "display_name": format!("StepFun · {suffix}"),
    })
}

/// 单次自动/手动捕获评估结果 (对齐 `StepFunWebLoginView` 状态机)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StepFunCaptureOutcome {
    /// 自动轮询尚未满足域名条件、尚无 Cookie、或远端尚未返回 200: 继续等待。
    Waiting { message: String },
    /// 手动触发但未找到目标 Cookie 或远端拒绝 (401 等): 给出明确诊断提示。
    Failed { message: String },
    /// 提取到 `Oasis-Token` 且通过远程 200 校验。
    Captured {
        token: String,
        site: StepFunSite,
        account_id: String,
        message: String,
    },
}

/// 评估当前窗口 URL 与 Cookie 列表, 命中时执行远程校验 (纯逻辑 + 可注入传输)。
pub fn evaluate_capture_with(
    site: StepFunSite,
    current_url: &str,
    cookies: &[CookieCandidate],
    is_manual: bool,
    transport: &dyn StepFunRemoteTransport,
) -> StepFunCaptureOutcome {
    if !is_manual && !page_allows_auto_capture(current_url, site) {
        return StepFunCaptureOutcome::Waiting {
            message: format!("等待 {} 登录完成中...", site.display_name()),
        };
    }
    let Some(token) = select_oasis_token(cookies, site) else {
        return if is_manual {
            StepFunCaptureOutcome::Failed {
                message: format!(
                    "未在当前 {} 会话中检测到有效 Oasis-Token，请确认已在网页中登录",
                    site.display_name()
                ),
            }
        } else {
            StepFunCaptureOutcome::Waiting {
                message: format!("等待 {} 登录完成中...", site.display_name()),
            }
        };
    };

    if verify_remote_with(&token, Some(site), transport) {
        let account_id = stepfun_account_id(&token);
        let prompt = if is_manual {
            format!(
                "🎉 已成功提取当前 {} Oasis-Token，正在绑定...",
                site.display_name()
            )
        } else {
            format!(
                "🎉 检测到 {} 登录完成，已提取 Oasis-Token",
                site.display_name()
            )
        };
        StepFunCaptureOutcome::Captured {
            token,
            site,
            account_id,
            message: prompt,
        }
    } else if is_manual {
        StepFunCaptureOutcome::Failed {
            message: format!(
                "{} 凭据校验未通过 (401 被拒绝)，请确保已在网页中完成登录并进入控制台",
                site.display_name()
            ),
        }
    } else {
        StepFunCaptureOutcome::Waiting {
            message: format!("等待 {} 登录完成中...", site.display_name()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn make_jwt(payload: &Value) -> String {
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
        let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(payload).unwrap());
        format!("{header}.{body}.sig")
    }

    struct MockTransport {
        status: Result<u16, String>,
        seen: Mutex<Vec<StepFunVerifyRequest>>,
    }

    impl MockTransport {
        fn new(status: Result<u16, String>) -> Self {
            Self {
                status,
                seen: Mutex::new(Vec::new()),
            }
        }
    }

    impl StepFunRemoteTransport for MockTransport {
        fn post_status(&self, request: &StepFunVerifyRequest) -> Result<u16, String> {
            self.seen.lock().unwrap().push(request.clone());
            self.status.clone()
        }
    }

    #[test]
    fn cookie_filter_checks_domain_name_and_length() {
        let cookies = vec![
            CookieCandidate {
                name: "other".into(),
                value: "long-enough-token-value".into(),
                domain: ".stepfun.com".into(),
            },
            CookieCandidate {
                name: "Oasis-Token".into(),
                value: "short".into(),
                domain: ".stepfun.com".into(),
            },
            CookieCandidate {
                name: "Oasis-Token".into(),
                value: "global-token-value-12345".into(),
                domain: ".stepfun.ai".into(),
            },
            CookieCandidate {
                name: "Oasis-Token".into(),
                value: "  domestic-token-value-67890  ".into(),
                domain: "platform.stepfun.com".into(),
            },
        ];
        assert_eq!(
            select_oasis_token(&cookies, StepFunSite::Domestic).as_deref(),
            Some("domestic-token-value-67890")
        );
        assert_eq!(
            select_oasis_token(&cookies, StepFunSite::Global).as_deref(),
            Some("global-token-value-12345")
        );
    }

    #[test]
    fn auto_capture_requires_matching_site_url_and_rejects_not_found() {
        assert!(page_allows_auto_capture(
            "https://platform.stepfun.com/step-plan",
            StepFunSite::Domestic
        ));
        assert!(!page_allows_auto_capture(
            "https://platform.stepfun.com/_not-found",
            StepFunSite::Domestic
        ));
        assert!(!page_allows_auto_capture(
            "https://platform.stepfun.ai/plan-subscribe",
            StepFunSite::Domestic
        ));
        assert!(page_allows_auto_capture(
            "https://platform.stepfun.ai/plan-subscribe",
            StepFunSite::Global
        ));
    }

    #[test]
    fn verify_request_maps_site_app_id_headers_and_device_id() {
        let domestic_jwt = make_jwt(&json!({"app_id": 10300, "device_id": "dev-cn-1"}));
        let req_cn = build_verify_request(&domestic_jwt, Some(StepFunSite::Domestic));
        assert_eq!(req_cn.url, DOMESTIC_RATE_LIMIT_URL);
        let headers_cn: std::collections::HashMap<_, _> = req_cn.headers.into_iter().collect();
        assert_eq!(
            headers_cn.get("Oasis-appID").map(String::as_str),
            Some("10300")
        );
        assert_eq!(
            headers_cn.get("Oasis-Language").map(String::as_str),
            Some("zh-CN")
        );
        assert_eq!(
            headers_cn.get("Oasis-Webid").map(String::as_str),
            Some("dev-cn-1")
        );
        assert_eq!(
            headers_cn.get("Origin").map(String::as_str),
            Some("https://platform.stepfun.com")
        );

        let global_jwt = format!(
            "prefix...{}",
            make_jwt(&json!({"app_id": 20700, "device_id": "dev-intl-9"}))
        );
        let req_intl = build_verify_request(&global_jwt, Some(StepFunSite::Global));
        assert_eq!(req_intl.url, GLOBAL_RATE_LIMIT_URL);
        let headers_intl: std::collections::HashMap<_, _> = req_intl.headers.into_iter().collect();
        assert_eq!(
            headers_intl.get("Oasis-appID").map(String::as_str),
            Some("20700")
        );
        assert_eq!(
            headers_intl.get("Oasis-Language").map(String::as_str),
            Some("en-US")
        );
        assert_eq!(
            headers_intl.get("Oasis-Webid").map(String::as_str),
            Some("dev-intl-9")
        );
    }

    #[test]
    fn evaluate_capture_accepts_200_and_rejects_non_200_or_missing_cookie() {
        let token = make_jwt(&json!({"app_id": 10300, "device_id": "d1"}));
        let cookies = vec![CookieCandidate {
            name: "Oasis-Token".into(),
            value: token.clone(),
            domain: ".stepfun.com".into(),
        }];

        let ok_transport = MockTransport::new(Ok(200));
        let outcome = evaluate_capture_with(
            StepFunSite::Domestic,
            "https://platform.stepfun.com/step-plan",
            &cookies,
            false,
            &ok_transport,
        );
        assert!(matches!(outcome, StepFunCaptureOutcome::Captured { .. }));
        assert_eq!(ok_transport.seen.lock().unwrap().len(), 1);

        let denied = MockTransport::new(Ok(401));
        let manual_fail = evaluate_capture_with(
            StepFunSite::Domestic,
            "https://platform.stepfun.com/step-plan",
            &cookies,
            true,
            &denied,
        );
        assert!(
            matches!(manual_fail, StepFunCaptureOutcome::Failed { ref message } if message.contains("401 被拒绝"))
        );

        let auto_wait = evaluate_capture_with(
            StepFunSite::Domestic,
            "https://platform.stepfun.com/step-plan",
            &cookies,
            false,
            &denied,
        );
        assert!(matches!(auto_wait, StepFunCaptureOutcome::Waiting { .. }));
    }

    #[test]
    fn clear_session_selects_only_target_site_cookies() {
        let cookies = vec![
            CookieCandidate {
                name: "Oasis-Token".into(),
                value: "cn-token-123456".into(),
                domain: ".stepfun.com".into(),
            },
            CookieCandidate {
                name: "session".into(),
                value: "s1".into(),
                domain: "platform.stepfun.com".into(),
            },
            CookieCandidate {
                name: "Oasis-Token".into(),
                value: "ai-token-123456".into(),
                domain: ".stepfun.ai".into(),
            },
        ];
        let cleared_cn = cookies_to_clear(&cookies, StepFunSite::Domestic);
        assert_eq!(cleared_cn.len(), 2);
        assert!(cleared_cn.iter().all(|c| c.domain.contains("stepfun.com")));

        let cleared_ai = cookies_to_clear(&cookies, StepFunSite::Global);
        assert_eq!(cleared_ai.len(), 1);
        assert_eq!(cleared_ai[0].domain, ".stepfun.ai");
    }
}
