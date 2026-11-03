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
    UnknownCountry,
    InvalidConfig,
    China,
    Mismatch,
}

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
                let request = HttpRequest {
                    method: "GET".to_owned(),
                    url: "https://cloudflare.com/cdn-cgi/trace".to_owned(),
                    headers: BTreeMap::new(),
                    body: None,
                    timeout: Duration::from_secs(3),
                    max_response_body_bytes: 4096,
                };
                let response = http
                    .send_via_loopback_proxy(port, request, cancellation)
                    .map_err(|_| ProbeError::Timeout)?;
                if response.status != 200 || response.body.len() > 4096 {
                    return Err(ProbeError::Timeout);
                }
                parse_trace(&response.body)
            })
            .clone()
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
