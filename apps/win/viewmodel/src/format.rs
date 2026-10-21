//! 展示格式化 —— 对齐 mac `PanelModels.swift` 的 `PanelFormat`。

/// 美元转人民币汇率; 暂为固定常量, 后续可做成配置项 (与 mac 一致)。
pub const CNY_PER_USD: f64 = 7.2;

/// token 计数 K/M/B 格式化: 900 -> "900", 9000 -> "9K", 70500 -> "70.5K", 1.2M, 3.53B。
/// B 档保留两位小数 (mac `PanelFormat.tokenCount` 同口径), 半年合计等 ≥1B 数值
/// 不得退化成 "6235.9M"。
pub fn token_count(value: i64) -> String {
    if value < 1000 {
        return value.to_string();
    }
    if value < 1_000_000 {
        return format!(
            "{}K",
            trim_decimal(&format!("{:.1}", value as f64 / 1000.0))
        );
    }
    if value < 1_000_000_000 {
        return format!(
            "{}M",
            trim_decimal(&format!("{:.1}", value as f64 / 1_000_000.0))
        );
    }
    format!(
        "{}B",
        trim_decimal(&format!("{:.2}", value as f64 / 1_000_000_000.0))
    )
}

/// 成本文案: 输入 USD, 按 cnyPerUsd 换算为人民币, 至少两位小数, 最多三位
/// (如 "≈ ¥2.70")。裁剪循环与 Swift `costText` 逐字符对齐。
pub fn cost_text(usd: f64) -> String {
    let cny = usd * CNY_PER_USD;
    let mut text = format!("{cny:.3}");
    while text.ends_with('0')
        && text
            .split('.')
            .next_back()
            .is_some_and(|frac| frac.len() > 2)
    {
        text.pop();
    }
    format!("≈ ¥{text}")
}

/// 余额文案, 左右排版右侧大数字 (mockup "¥ 38.21")。
pub fn balance_text(amount: f64, currency: Option<&str>) -> String {
    let currency = currency.unwrap_or("CNY").to_uppercase();
    let text = format!("{amount:.2}");
    match currency.as_str() {
        "CNY" | "RMB" => format!("¥ {text}"),
        "USD" => format!("$ {text}"),
        other => format!("{other} {text}"),
    }
}

/// Credits 剩余余额文案: 千分位 + 两位小数纯数字 (如 "2,998.12"), 非货币不加符号;
/// 分隔符固定半角逗号, 与 mac `PanelFormat.creditsText` 逐字符对齐 (golden 对拍契约)。
pub fn credits_text(amount: f64) -> String {
    let formatted = format!("{amount:.2}");
    let (mut digits, fraction) = match formatted.split_once('.') {
        Some((int_part, frac)) => (int_part.to_owned(), format!(".{frac}")),
        None => (formatted.clone(), String::new()),
    };
    let is_negative = digits.starts_with('-');
    if is_negative {
        digits.remove(0);
    }
    let mut grouped = String::new();
    while digits.len() > 3 {
        let split_at = digits.len() - 3;
        grouped = format!(",{}{}", &digits[split_at..], grouped);
        digits.truncate(split_at);
    }
    format!(
        "{}{digits}{grouped}{fraction}",
        if is_negative { "-" } else { "" }
    )
}

/// 裁掉小数部分的末尾 0 与悬空小数点 ("6.70" -> "6.7", "2.00" -> "2"),
/// 与 mac `PanelFormat.trimDecimal` 逐字符对齐; 无小数点的整数原样返回。
fn trim_decimal(text: &str) -> String {
    if !text.contains('.') {
        return text.to_owned();
    }
    text.trim_end_matches('0').trim_end_matches('.').to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_count_matches_mac_formatting() {
        assert_eq!(token_count(900), "900");
        assert_eq!(token_count(9000), "9K");
        assert_eq!(token_count(70500), "70.5K");
        assert_eq!(token_count(999_999), "1000K");
        assert_eq!(token_count(1_000_000), "1M");
        assert_eq!(token_count(124_000), "124K");
    }

    #[test]
    fn token_count_switches_to_billions_like_mac() {
        assert_eq!(token_count(999_999_999), "1000M");
        assert_eq!(token_count(1_000_000_000), "1B");
        assert_eq!(token_count(6_235_900_000), "6.24B");
        assert_eq!(token_count(6_748_200_000), "6.75B");
        // 4.145 的二进制近似值略小于 4.145, 与 C printf (mac String(format:)) 同为 4.14。
        assert_eq!(token_count(4_145_000_000), "4.14B");
        assert_eq!(token_count(4_146_000_000), "4.15B");
        assert_eq!(token_count(1_700_000_000), "1.7B");
        assert_eq!(token_count(12_000_000_000), "12B");
    }

    #[test]
    fn cost_text_keeps_two_to_three_fraction_digits() {
        assert_eq!(cost_text(0.375), "≈ ¥2.70");
        assert_eq!(cost_text(0.3753), "≈ ¥2.702");
        assert_eq!(cost_text(0.0), "≈ ¥0.00");
    }

    #[test]
    fn balance_text_maps_currency_symbols() {
        assert_eq!(balance_text(38.21, None), "¥ 38.21");
        assert_eq!(balance_text(38.21, Some("rmb")), "¥ 38.21");
        assert_eq!(balance_text(1.5, Some("USD")), "$ 1.50");
        assert_eq!(balance_text(1.5, Some("JPY")), "JPY 1.50");
    }

    #[test]
    fn credits_text_groups_thousands_like_mac() {
        assert_eq!(credits_text(2998.116571), "2,998.12");
        assert_eq!(credits_text(0.0), "0.00");
        assert_eq!(credits_text(999.995), "1,000.00");
        assert_eq!(credits_text(1_000_000.0), "1,000,000.00");
        assert_eq!(credits_text(-1234.5), "-1,234.50");
    }
}
