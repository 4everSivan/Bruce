//! 专用代理的出口探测与受管订阅放行决策。

use collector_provider::{HttpClient, HttpRequest};
use collector_runtime::CancellationToken;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::net::IpAddr;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Trace {
    pub country: String,
    pub masked_ip: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ProbeError {
    Timeout,
    ProxyUnreachable,
    ProxyAuth,
    BadStatus,
    UnknownCountry,
    InvalidConfig,
    China,
    Mismatch,
}

impl ProbeError {
    /// 瞬态失败允许用备用信标再试一次；配置/认证问题重试也不会改变结论。
    fn is_transient(self) -> bool {
        matches!(
            self,
            Self::Timeout | Self::ProxyUnreachable | Self::BadStatus | Self::UnknownCountry
        )
    }
}

/// 首次探测使用 Cloudflare 主信标；失败后退避并改用备用的 1.1.1.1 信标。
const PRIMARY_TRACE_URL: &str = "https://cloudflare.com/cdn-cgi/trace";
const FALLBACK_TRACE_URL: &str = "https://1.1.1.1/cdn-cgi/trace";
const PRIMARY_TIMEOUT: Duration = Duration::from_secs(3);
const FALLBACK_TIMEOUT: Duration = Duration::from_secs(5);
const RETRY_BACKOFF: Duration = Duration::from_millis(400);
const MAX_TRACE_BODY_BYTES: usize = 4096;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Rule {
    pub country: String,
    pub port: u16,
}

fn is_country_code(code: &str) -> bool {
    // ISO 3166-1 alpha-2 (249 个正式分配项)；拒绝 Trace 的未知及 CLDR 宏地区码。
    const COUNTRIES: &str = "AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ \
        BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ \
        CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ \
        DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR \
        GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY \
        HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP \
        KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY \
        MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ \
        NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY \
        QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ \
        TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ \
        VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW";
    COUNTRIES
        .split_ascii_whitespace()
        .any(|country| country == code)
}

/// 缺字段表示未启用；出现但格式无效则阻断，不能退化为未分组。
pub(crate) fn rule_for(raw: Option<&Value>, provider: &str) -> Result<Option<Rule>, ProbeError> {
    let Some(raw) = raw else { return Ok(None) };
    let rules = raw.as_object().ok_or(ProbeError::InvalidConfig)?;
    let Some(rule) = rules.get(provider) else {
        return Ok(None);
    };
    let rule = rule.as_object().ok_or(ProbeError::InvalidConfig)?;
    let country = rule
        .get("country")
        .and_then(Value::as_str)
        .ok_or(ProbeError::InvalidConfig)?;
    if !is_country_code(country) {
        return Err(ProbeError::InvalidConfig);
    }
    let port = rule
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .filter(|value| *value != 0)
        .ok_or(ProbeError::InvalidConfig)?;
    Ok(Some(Rule {
        country: country.to_owned(),
        port,
    }))
}

/// 同一轮次、同一端口共享一次结果；不同端口不能复用结果。
type SharedProbe = Arc<OnceLock<Result<Trace, ProbeError>>>;

#[derive(Default)]
pub(crate) struct ProbeCache {
    entries: Mutex<HashMap<u16, SharedProbe>>,
}

impl ProbeCache {
    pub(crate) fn probe(
        &self,
        port: u16,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Trace, ProbeError> {
        if port == 0 {
            return Err(ProbeError::InvalidConfig);
        }
        let entry = {
            let mut entries = self.entries.lock().map_err(|_| ProbeError::Timeout)?;
            entries.entry(port).or_default().clone()
        };
        entry
            .get_or_init(|| {
                match attempt(port, PRIMARY_TRACE_URL, PRIMARY_TIMEOUT, http, cancellation) {
                    Ok(trace) => Ok(trace),
                    Err(primary) if primary.is_transient() => {
                        // 两次尝试之间允许取消；探测不在后台线程里长睡。
                        if cancellation.check().is_err() {
                            return Err(ProbeError::Timeout);
                        }
                        std::thread::sleep(RETRY_BACKOFF);
                        if cancellation.check().is_err() {
                            return Err(ProbeError::Timeout);
                        }
                        attempt(
                            port,
                            FALLBACK_TRACE_URL,
                            FALLBACK_TIMEOUT,
                            http,
                            cancellation,
                        )
                    }
                    Err(error) => Err(error),
                }
            })
            .clone()
    }
}

/// 单次信标请求；任何传输错误按代理错误分类，非 200 或响应超限归为信标异常。
fn attempt(
    port: u16,
    url: &str,
    timeout: Duration,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
) -> Result<Trace, ProbeError> {
    let request = HttpRequest {
        method: "GET".to_owned(),
        url: url.to_owned(),
        headers: BTreeMap::new(),
        body: None,
        timeout,
        max_response_body_bytes: MAX_TRACE_BODY_BYTES,
    };
    let response = http
        .send_via_loopback_proxy(port, request, cancellation)
        .map_err(classify_transport)?;
    if response.status != 200 || response.body.len() > MAX_TRACE_BODY_BYTES {
        return Err(ProbeError::BadStatus);
    }
    parse_trace(&response.body)
}

/// 代理传输错误分类：供上层区分“代理没起来/需认证”与真正的探测超时。
fn classify_transport(error: collector_provider::ProviderError) -> ProbeError {
    match error.diagnostic.code.as_str() {
        "EGRESS_CONFIG_INVALID" => ProbeError::InvalidConfig,
        "EGRESS_PROXY_AUTH" => ProbeError::ProxyAuth,
        "EGRESS_PROXY_UNAVAILABLE" | "EGRESS_PROXY_UNREACHABLE" => ProbeError::ProxyUnreachable,
        _ => ProbeError::Timeout,
    }
}

pub(crate) fn decide(expected: &str, trace: &Trace) -> Result<(), ProbeError> {
    if !is_country_code(expected) {
        return Err(ProbeError::InvalidConfig);
    }
    if trace.country == "CN" && expected != "CN" {
        return Err(ProbeError::China);
    }
    if trace.country != expected {
        return Err(ProbeError::Mismatch);
    }
    Ok(())
}

fn parse_trace(body: &[u8]) -> Result<Trace, ProbeError> {
    let content = std::str::from_utf8(body).map_err(|_| ProbeError::UnknownCountry)?;
    let mut country = None;
    let mut ip = None;
    for line in content.lines() {
        if let Some(value) = line.strip_prefix("loc=") {
            if country.replace(value).is_some() {
                return Err(ProbeError::UnknownCountry);
            }
        }
        if let Some(value) = line.strip_prefix("ip=") {
            if ip.replace(value).is_some() {
                return Err(ProbeError::UnknownCountry);
            }
        }
    }
    let country = country.ok_or(ProbeError::UnknownCountry)?;
    if !is_country_code(country) {
        return Err(ProbeError::UnknownCountry);
    }
    let address = ip
        .ok_or(ProbeError::UnknownCountry)?
        .parse::<IpAddr>()
        .map_err(|_| ProbeError::UnknownCountry)?;
    let masked_ip = match address {
        IpAddr::V4(address) => {
            let octets = address.octets();
            format!("{}.{}.***.***", octets[0], octets[1])
        }
        IpAddr::V6(address) => {
            let parts = address.segments();
            format!(
                "{:x}:{:x}:****:****:****:****:****:****",
                parts[0], parts[1]
            )
        }
    };
    Ok(Trace {
        country: country.to_owned(),
        masked_ip,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use collector_provider::{HttpResponse, ProviderError};
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct FakeHttp(AtomicUsize);

    impl HttpClient for FakeHttp {
        fn send(
            &self,
            _: HttpRequest,
            _: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            panic!("出口探测不得直连")
        }

        fn send_via_loopback_proxy(
            &self,
            port: u16,
            _: HttpRequest,
            _: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(HttpResponse {
                status: 200,
                body: format!(
                    "ip=192.0.2.1\nloc={}\n",
                    if port == 1 { "JP" } else { "CN" }
                )
                .into_bytes(),
            })
        }
    }

    #[test]
    fn validates_and_masks_trace() {
        let trace = parse_trace(b"ip=192.0.2.1\nloc=JP\n").unwrap();
        assert_eq!(trace.masked_ip, "192.0.***.***");
        assert_eq!(decide("JP", &trace), Ok(()));
        assert_eq!(decide("US", &trace), Err(ProbeError::Mismatch));
        assert!(parse_trace(b"ip=192.0.2.1\nloc=XX\n").is_err());
        assert!(parse_trace(b"ip=192.0.2.1\nloc=ZZ\n").is_err());
        assert!(parse_trace(b"ip=192.0.2.1\nloc=JP\nloc=US\n").is_err());
        assert!(parse_trace(b"ip=invalid\nloc=JP\n").is_err());
        let ipv6 = parse_trace(b"ip=2001:db8::1\nloc=US\n").unwrap();
        assert_eq!(ipv6.masked_ip, "2001:db8:****:****:****:****:****:****");
    }

    struct SequencedHttp {
        calls: Mutex<Vec<String>>,
        fail_remaining: AtomicUsize,
        error_code: &'static str,
        body: &'static str,
    }

    impl SequencedHttp {
        fn new(failures: usize, error_code: &'static str, body: &'static str) -> Self {
            Self {
                calls: Mutex::new(Vec::new()),
                fail_remaining: AtomicUsize::new(failures),
                error_code,
                body,
            }
        }
    }

    impl HttpClient for SequencedHttp {
        fn send(
            &self,
            _: HttpRequest,
            _: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            panic!("出口探测不得直连")
        }

        fn send_via_loopback_proxy(
            &self,
            _: u16,
            request: HttpRequest,
            _: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            self.calls.lock().unwrap().push(request.url);
            let remaining = self.fail_remaining.load(Ordering::SeqCst);
            if remaining > 0 {
                self.fail_remaining.fetch_sub(1, Ordering::SeqCst);
                return Err(ProviderError::new(
                    self.error_code,
                    "request",
                    "fixture",
                    true,
                ));
            }
            Ok(HttpResponse {
                status: 200,
                body: self.body.as_bytes().to_vec(),
            })
        }
    }

    #[test]
    fn retries_with_fallback_beacon_after_transient_failure() {
        let cache = ProbeCache::default();
        let http = SequencedHttp::new(1, "PROVIDER_TRANSPORT_ERROR", "ip=192.0.2.1\nloc=US\n");
        let trace = cache.probe(7897, &http, &CancellationToken::new()).unwrap();
        assert_eq!(trace.country, "US");
        let calls = http.calls.lock().unwrap().clone();
        assert_eq!(
            calls,
            vec![PRIMARY_TRACE_URL.to_owned(), FALLBACK_TRACE_URL.to_owned()]
        );
    }

    #[test]
    fn final_failure_is_cached_after_both_attempts() {
        let cache = ProbeCache::default();
        let http = SequencedHttp::new(2, "EGRESS_PROXY_UNREACHABLE", "");
        let token = CancellationToken::new();
        assert_eq!(
            cache.probe(7897, &http, &token),
            Err(ProbeError::ProxyUnreachable)
        );
        assert_eq!(
            cache.probe(7897, &http, &token),
            Err(ProbeError::ProxyUnreachable)
        );
        assert_eq!(
            http.calls.lock().unwrap().len(),
            2,
            "同轮次最终结论只探测一组"
        );
    }

    #[test]
    fn transport_timeouts_on_both_beacons_are_probe_timeout() {
        // C239: 传输层超时保留 PROVIDER_TRANSPORT_ERROR, 主备两次都超时才判探测超时。
        let cache = ProbeCache::default();
        let http = SequencedHttp::new(2, "PROVIDER_TRANSPORT_ERROR", "");
        assert_eq!(
            cache.probe(7897, &http, &CancellationToken::new()),
            Err(ProbeError::Timeout)
        );
        assert_eq!(
            http.calls.lock().unwrap().clone(),
            vec![PRIMARY_TRACE_URL.to_owned(), FALLBACK_TRACE_URL.to_owned()]
        );
    }

    #[test]
    fn proxy_auth_failure_is_not_retried_with_fallback() {
        let cache = ProbeCache::default();
        let http = SequencedHttp::new(1, "EGRESS_PROXY_AUTH", "");
        assert_eq!(
            cache.probe(7897, &http, &CancellationToken::new()),
            Err(ProbeError::ProxyAuth)
        );
        assert_eq!(http.calls.lock().unwrap().len(), 1);
    }

    #[test]
    fn bad_status_falls_back_to_secondary_beacon() {
        struct StatusHttp(AtomicUsize);
        impl HttpClient for StatusHttp {
            fn send(
                &self,
                _: HttpRequest,
                _: &CancellationToken,
            ) -> Result<HttpResponse, ProviderError> {
                panic!("出口探测不得直连")
            }

            fn send_via_loopback_proxy(
                &self,
                _: u16,
                _: HttpRequest,
                _: &CancellationToken,
            ) -> Result<HttpResponse, ProviderError> {
                let call = self.0.fetch_add(1, Ordering::SeqCst);
                Ok(HttpResponse {
                    status: if call == 0 { 403 } else { 200 },
                    body: if call == 0 {
                        b"blocked".to_vec()
                    } else {
                        b"ip=192.0.2.1\nloc=JP\n".to_vec()
                    },
                })
            }
        }
        let cache = ProbeCache::default();
        let http = StatusHttp(AtomicUsize::new(0));
        let trace = cache.probe(7897, &http, &CancellationToken::new()).unwrap();
        assert_eq!(trace.country, "JP");
        assert_eq!(http.0.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn probes_once_per_port_and_blocks_china_for_foreign_groups() {
        let cache = ProbeCache::default();
        let http = FakeHttp(AtomicUsize::new(0));
        let token = CancellationToken::new();
        let jp = cache.probe(1, &http, &token).unwrap();
        assert_eq!(cache.probe(1, &http, &token), Ok(jp));
        let china = cache.probe(2, &http, &token).unwrap();
        assert_eq!(decide("JP", &china), Err(ProbeError::China));
        assert_eq!(decide("CN", &china), Ok(()));
        assert_eq!(http.0.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn concurrent_accounts_share_the_probe() {
        let cache = ProbeCache::default();
        let http = FakeHttp(AtomicUsize::new(0));
        let token = CancellationToken::new();
        std::thread::scope(|scope| {
            for _ in 0..8 {
                scope.spawn(|| assert_eq!(cache.probe(1, &http, &token).unwrap().country, "JP"));
            }
        });
        assert_eq!(http.0.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn malformed_config_is_not_unmanaged() {
        assert_eq!(rule_for(None, "codex"), Ok(None));
        assert_eq!(rule_for(Some(&serde_json::json!({})), "codex"), Ok(None));
        for raw in [
            serde_json::json!(null),
            serde_json::json!({"codex": {"country":"JP"}}),
            serde_json::json!({"codex": {"country":"JP", "port":0}}),
        ] {
            assert_eq!(
                rule_for(Some(&raw), "codex"),
                Err(ProbeError::InvalidConfig)
            );
        }
    }
}
