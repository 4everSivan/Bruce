//! 出口线路测试 (C264, design/11 §3.1): 经本机回环专用代理访问 Cloudflare Trace，
//! 返回与 mac `EgressRouteTester` 同口径的脱敏结论。该测试不是持续保证，仅用于设置页
//! 「测试线路」即时反馈；采集侧放行/阻断仍由共享 `collector-application` 引擎判定。

use serde_json::Value;
use std::net::IpAddr;
use std::time::Duration;

const PRIMARY_TRACE_URL: &str = "https://cloudflare.com/cdn-cgi/trace";
const FALLBACK_TRACE_URL: &str = "https://1.1.1.1/cdn-cgi/trace";
const PRIMARY_TIMEOUT: Duration = Duration::from_secs(3);
const FALLBACK_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_TRACE_BYTES: u64 = 4096;

struct Trace {
    country: String,
    masked_ip: String,
}

fn is_country_code(code: &str) -> bool {
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

fn parse_trace(body: &[u8]) -> Option<Trace> {
    let content = std::str::from_utf8(body).ok()?;
    let mut country = None;
    let mut ip = None;
    for line in content.lines() {
        if let Some(value) = line.strip_prefix("loc=") {
            if country.replace(value).is_some() {
                return None;
            }
        }
        if let Some(value) = line.strip_prefix("ip=") {
            if ip.replace(value).is_some() {
                return None;
            }
        }
    }
    let country = country?;
    if !is_country_code(country) {
        return None;
    }
    let address = ip?.parse::<IpAddr>().ok()?;
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
    Some(Trace {
        country: country.to_owned(),
        masked_ip,
    })
}

fn probe(port: u16) -> Result<Trace, String> {
    let proxy = ureq::Proxy::new(format!("http://127.0.0.1:{port}"))
        .map_err(|_| "EGRESS_CONFIG_INVALID".to_owned())?;
    let attempt = |url: &str, timeout: Duration| -> Result<Trace, String> {
        let agent = ureq::AgentBuilder::new()
            .proxy(proxy.clone())
            .timeout(timeout)
            .build();
        let response = agent
            .get(url)
            .call()
            .map_err(|error| classify_proxy_error(&error))?;
        let status = response.status();
        if status != 200 {
            return Err("EGRESS_BAD_STATUS".to_owned());
        }
        let mut body = Vec::new();
        use std::io::Read;
        response
            .into_reader()
            .take(MAX_TRACE_BYTES)
            .read_to_end(&mut body)
            .map_err(|_| "EGRESS_BAD_STATUS".to_owned())?;
        parse_trace(&body).ok_or_else(|| "EGRESS_COUNTRY_UNKNOWN".to_owned())
    };
    attempt(PRIMARY_TRACE_URL, PRIMARY_TIMEOUT)
        .or_else(|_| attempt(FALLBACK_TRACE_URL, FALLBACK_TIMEOUT))
}

fn classify_proxy_error(error: &ureq::Error) -> String {
    match error {
        ureq::Error::Status(_, _) => "EGRESS_BAD_STATUS".to_owned(),
        ureq::Error::Transport(transport) => {
            let text = transport.to_string().to_lowercase();
            if text.contains("407") || text.contains("proxy authentication") {
                "EGRESS_PROXY_AUTH".to_owned()
            } else if text.contains("refused")
                || text.contains("unreachable")
                || text.contains("connect")
            {
                "EGRESS_PROXY_UNREACHABLE".to_owned()
            } else {
                "EGRESS_PROBE_TIMEOUT".to_owned()
            }
        }
    }
}

fn format_result(expected: &str, result: Result<Trace, String>) -> String {
    match result {
        Ok(trace) if trace.country == expected => {
            format!("线路探测匹配 · {} · {}", trace.country, trace.masked_ip)
        }
        Ok(trace) if trace.country == "CN" => "当前线路出口为国内（CN）· 已拦截".to_owned(),
        Ok(trace) => format!(
            "出口国家不匹配 · 预期 {} · 探测为 {} · {}",
            expected, trace.country, trace.masked_ip
        ),
        Err(code) => match code.as_str() {
            "EGRESS_PROXY_AUTH" => "专用代理需要认证 · 已拦截".to_owned(),
            "EGRESS_PROXY_UNREACHABLE" => "专用代理连接失败 · 已拦截".to_owned(),
            "EGRESS_PROBE_TIMEOUT" => "线路探测超时 · 已拦截".to_owned(),
            "EGRESS_BAD_STATUS" => "出口信标返回异常 · 已拦截".to_owned(),
            "EGRESS_CONFIG_INVALID" => "端口无效 · 已拦截".to_owned(),
            _ => "无法识别出口国家 · 已拦截".to_owned(),
        },
    }
}

/// 设置页「测试线路」入口：返回可展示的脱敏结论字符串（永不返回原始 IP）。
pub fn test_route(country: &str, port: u16) -> Result<String, String> {
    if !is_country_code(country) || port == 0 {
        return Err("EGRESS_CONFIG_INVALID".to_owned());
    }
    Ok(format_result(country, probe(port)))
}

/// 供 Tauri 命令直接消费的 JSON 形态。
pub fn test_route_json(country: &str, port: u16) -> Result<Value, String> {
    let result = test_route(country, port)?;
    Ok(serde_json::json!({
        "result": result,
        "tone": if result.starts_with("线路探测匹配") {
            "ok"
        } else if result.starts_with("出口国家不匹配") || result.contains("国内") {
            "danger"
        } else {
            "warn"
        },
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_parsing_masks_ips_and_rejects_bad_input() {
        let trace = parse_trace(b"ip=192.0.2.1\nloc=JP\n").unwrap();
        assert_eq!(trace.country, "JP");
        assert_eq!(trace.masked_ip, "192.0.***.***");
        let v6 = parse_trace(b"ip=2001:db8::1\nloc=US\n").unwrap();
        assert_eq!(v6.masked_ip, "2001:db8:****:****:****:****:****:****");
        assert!(parse_trace(b"ip=192.0.2.1\nloc=XX\n").is_none());
        assert!(parse_trace(b"ip=192.0.2.1\nloc=JP\nloc=US\n").is_none());
        assert!(parse_trace(b"ip=nope\nloc=JP\n").is_none());
    }

    #[test]
    fn result_text_matches_presentation_contract() {
        let matched = format_result(
            "JP",
            Ok(Trace {
                country: "JP".to_owned(),
                masked_ip: "192.0.***.***".to_owned(),
            }),
        );
        assert_eq!(matched, "线路探测匹配 · JP · 192.0.***.***");
        let mismatch = format_result(
            "JP",
            Ok(Trace {
                country: "US".to_owned(),
                masked_ip: "203.0.***.***".to_owned(),
            }),
        );
        assert_eq!(
            mismatch,
            "出口国家不匹配 · 预期 JP · 探测为 US · 203.0.***.***"
        );
        let china = format_result(
            "JP",
            Ok(Trace {
                country: "CN".to_owned(),
                masked_ip: "1.2.***.***".to_owned(),
            }),
        );
        assert_eq!(china, "当前线路出口为国内（CN）· 已拦截");
        assert_eq!(
            format_result("JP", Err("EGRESS_PROXY_AUTH".to_owned())),
            "专用代理需要认证 · 已拦截"
        );
        assert!(test_route("J", 18081).is_err(), "非法国家直接拒绝");
        assert!(test_route("JP", 0).is_err(), "零端口直接拒绝");
    }
}
