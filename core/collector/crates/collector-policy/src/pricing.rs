//! 价卡校验 / Diff / 防降级的纯策略 (C263, design/08 SharedPolicyCore)。
//!
//! 复用 `collector-domain::pricing::CatalogFile` 的严格校验与 `updatedAt` 版本比较,
//! 把「能否采用远端价卡」收敛为一次判定: schema/字段/模型数合法且不早于内置基线。
//! 不做网络 / 文件 I/O; 输入输出为 JSON `Value`。

use std::cmp::Ordering;

use collector_domain::pricing::{
    compare_updated_at, is_valid_updated_at, CatalogFile, CatalogValidationError,
};
use serde_json::Value;

/// 采用远端价卡与内置基线的判定结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogDecision {
    /// 可作为活动价卡; 携带归一后的版本与模型数供调用方落盘/展示。
    Accept {
        updated_at: String,
        model_count: usize,
    },
    /// 拒绝并给出稳定错误码 (两端展示与日志共用)。
    Reject { code: &'static str, message: String },
}

/// 校验一份远端价卡: JSON/schema/模型约束必须合法, 且 `updatedAt` 不早于内置基线。
/// `builtin_updated_at` 由调用方注入 (mac/Windows 均取 domain 内置基线), 便于测试。
pub fn validate_catalog(raw: &Value, builtin_updated_at: &str) -> CatalogDecision {
    if !is_valid_updated_at(builtin_updated_at) {
        return CatalogDecision::Reject {
            code: "PRICING_INVALID_BASELINE",
            message: format!("内置基线 updatedAt 无效: {builtin_updated_at}"),
        };
    }
    let file: CatalogFile = match serde_json::from_value(raw.clone()) {
        Ok(file) => file,
        Err(error) => {
            return CatalogDecision::Reject {
                code: "PRICING_INVALID_JSON",
                message: format!("价卡不是合法的 CatalogFile: {error}"),
            }
        }
    };
    if let Err(error) = file.validate() {
        return CatalogDecision::Reject {
            code: catalog_error_code(&error),
            message: error.to_string(),
        };
    }
    if file.is_older_than(builtin_updated_at) {
        return CatalogDecision::Reject {
            code: "PRICING_OLDER_THAN_BUILTIN",
            message: format!(
                "远端价卡 {} 早于内置基线 {builtin_updated_at}, 拒绝降级",
                file.updated_at
            ),
        };
    }
    CatalogDecision::Accept {
        updated_at: file.updated_at,
        model_count: file.models.len(),
    }
}

/// 两份价卡版本比较 (同日支持 `.N` 修订号); 供 Diff / 跳过重复下载判定。
pub fn compare_catalog_versions(a: &str, b: &str) -> Ordering {
    compare_updated_at(a, b)
}

/// `candidate` 是否严格新于 `current` (用于避免无变化时重复落盘)。
pub fn is_newer_catalog(candidate: &str, current: &str) -> bool {
    compare_updated_at(candidate, current) == Ordering::Greater
}

fn catalog_error_code(error: &CatalogValidationError) -> &'static str {
    match error {
        CatalogValidationError::Json(_) => "PRICING_INVALID_JSON",
        CatalogValidationError::UnsupportedSchemaVersion(_) => "PRICING_INVALID_SCHEMA_VERSION",
        CatalogValidationError::InvalidUpdatedAt(_) => "PRICING_INVALID_UPDATED_AT",
        CatalogValidationError::InvalidModelCount => "PRICING_INVALID_MODEL_COUNT",
        CatalogValidationError::InvalidModel(_) => "PRICING_INVALID_MODEL",
        CatalogValidationError::DuplicateModel(_) => "PRICING_DUPLICATE_MODEL",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn catalog(updated_at: &str) -> Value {
        json!({
            "schemaVersion": 1,
            "updatedAt": updated_at,
            "models": [{
                "model": "m1",
                "displayName": "Model 1",
                "vendor": "V",
                "input": 1.0,
                "output": 2.0,
                "cacheRead": 0.5,
                "note": ""
            }]
        })
    }

    #[test]
    fn accepts_catalog_not_older_than_baseline() {
        assert_eq!(
            validate_catalog(&catalog("2026-11-01"), "2026-11-01"),
            CatalogDecision::Accept {
                updated_at: "2026-11-01".to_owned(),
                model_count: 1
            }
        );
        assert!(matches!(
            validate_catalog(&catalog("2026-11-02"), "2026-11-01"),
            CatalogDecision::Accept { .. }
        ));
    }

    #[test]
    fn rejects_rolled_back_catalog() {
        assert_eq!(
            validate_catalog(&catalog("2026-10-31"), "2026-11-01"),
            CatalogDecision::Reject {
                code: "PRICING_OLDER_THAN_BUILTIN",
                message: "远端价卡 2026-10-31 早于内置基线 2026-11-01, 拒绝降级".to_owned()
            }
        );
    }

    #[test]
    fn rejects_invalid_schema_and_models() {
        let cases: [(&str, &Value); 3] = [
            (
                "PRICING_INVALID_SCHEMA_VERSION",
                &json!({"schemaVersion": 2, "updatedAt": "2026-11-01", "models": []}),
            ),
            (
                "PRICING_INVALID_UPDATED_AT",
                &json!({"schemaVersion": 1, "updatedAt": "2026/11/01", "models": [{"model": "m", "displayName": "M", "vendor": "V", "input": 1.0, "output": 2.0, "note": ""}]}),
            ),
            (
                "PRICING_INVALID_MODEL_COUNT",
                &json!({"schemaVersion": 1, "updatedAt": "2026-11-01", "models": []}),
            ),
        ];
        for (code, raw) in cases {
            match validate_catalog(raw, "2026-01-01") {
                CatalogDecision::Reject { code: actual, .. } => assert_eq!(actual, code),
                other => panic!("expected reject {code}, got {other:?}"),
            }
        }
    }

    #[test]
    fn rejects_non_json_shape() {
        match validate_catalog(&json!("not an object"), "2026-01-01") {
            CatalogDecision::Reject { code, .. } => assert_eq!(code, "PRICING_INVALID_JSON"),
            other => panic!("expected invalid json, got {other:?}"),
        }
    }

    #[test]
    fn version_compare_and_newer() {
        assert_eq!(
            compare_catalog_versions("2026-11-01.2", "2026-11-01.1"),
            Ordering::Greater
        );
        assert!(is_newer_catalog("2026-11-02", "2026-11-01"));
        assert!(!is_newer_catalog("2026-11-01", "2026-11-01"));
    }
}
