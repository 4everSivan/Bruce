//! 展示格式化 —— 对齐 mac `PanelModels.swift` 的 `PanelFormat`。

/// 美元转人民币汇率; 暂为固定常量, 后续可做成配置项 (与 mac 一致)。
pub const CNY_PER_USD: f64 = 7.2;

/// token 计数 K 格式化: 900 -> "900", 9000 -> "9K", 70500 -> "70.5K"。
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
    format!(
        "{}M",
        trim_decimal(&format!("{:.1}", value as f64 / 1_000_000.0))
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

fn trim_decimal(text: &str) -> String {
    text.strip_suffix(".0").unwrap_or(text).to_owned()
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
}
