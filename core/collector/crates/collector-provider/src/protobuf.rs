//! Bounded protobuf / gRPC-Web scanner and Grok billing parser (C053).

use crate::{clamp_percent, invalid_payload, service_result, window, ProviderError};
use serde_json::Value;

#[derive(Default)]
struct ProtoScan {
    varint: Vec<(Vec<u32>, u64)>,
    fixed32: Vec<(Vec<u32>, f32, usize)>,
}

fn read_varint(data: &[u8], index: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while *index < data.len() && shift < 64 {
        let byte = data[*index];
        *index += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
    }
    None
}

fn scan_protobuf(data: &[u8], depth: u8, path: &[u32], order: &mut usize, scan: &mut ProtoScan) {
    let mut index = 0usize;
    while index < data.len() {
        let field_start = index;
        let Some(key) = read_varint(data, &mut index) else {
            index = field_start.saturating_add(1);
            continue;
        };
        if key == 0 {
            index = field_start.saturating_add(1);
            continue;
        }
        let field_number = (key >> 3) as u32;
        let wire_type = key & 7;
        if field_number == 0 {
            index = field_start.saturating_add(1);
            continue;
        }
        let mut field_path = path.to_vec();
        field_path.push(field_number);
        match wire_type {
            0 => {
                if let Some(value) = read_varint(data, &mut index) {
                    scan.varint.push((field_path, value));
                } else {
                    index = field_start.saturating_add(1);
                }
            }
            1 => {
                if index + 8 > data.len() {
                    return;
                }
                index += 8;
            }
            2 => {
                let Some(length) =
                    read_varint(data, &mut index).and_then(|value| usize::try_from(value).ok())
                else {
                    index = field_start.saturating_add(1);
                    continue;
                };
                let Some(end) = index.checked_add(length) else {
                    index = field_start.saturating_add(1);
                    continue;
                };
                if end > data.len() {
                    index = field_start.saturating_add(1);
                    continue;
                }
                if depth < 4 {
                    scan_protobuf(&data[index..end], depth + 1, &field_path, order, scan);
                }
                index = end;
            }
            5 => {
                if index + 4 > data.len() {
                    return;
                }
                let value = f32::from_le_bytes(data[index..index + 4].try_into().unwrap());
                scan.fixed32.push((field_path, value, *order));
                *order += 1;
                index += 4;
            }
            _ => index = field_start.saturating_add(1),
        }
    }
}

fn grpc_data_frames(data: &[u8]) -> Option<Vec<&[u8]>> {
    let mut frames = Vec::new();
    let mut index = 0usize;
    while index < data.len() {
        if index + 5 > data.len() {
            return None;
        }
        let flags = data[index];
        let length = u32::from_be_bytes(data[index + 1..index + 5].try_into().ok()?) as usize;
        let start = index + 5;
        let end = start.checked_add(length)?;
        if end > data.len() {
            return None;
        }
        if flags & 0x80 == 0 {
            frames.push(&data[start..end]);
        }
        index = end;
    }
    Some(frames)
}

fn looks_like_protobuf(data: &[u8]) -> bool {
    data.first()
        .is_some_and(|byte| byte >> 3 > 0 && matches!(byte & 7, 0 | 1 | 2 | 5))
}

fn grok_window(resets_at: Option<i64>, now_epoch: i64) -> (&'static str, Option<u64>) {
    let Some(reset) = resets_at else {
        return ("额度", None);
    };
    let days = (((reset - now_epoch) as f64) / 86_400.0).round() as i64;
    if days < 1 {
        ("每 5 小时", Some(300))
    } else if (4..=12).contains(&days) {
        ("每周", Some(10080))
    } else if (20..=45).contains(&days) {
        ("每月", Some(43200))
    } else {
        ("额度", None)
    }
}

/// Parse Grok's gRPC-web/protobuf billing response using the shared bounded heuristic.
pub fn parse_grok_usage(body: &[u8], now_epoch: i64) -> Result<Option<Value>, ProviderError> {
    let frames = grpc_data_frames(body).filter(|frames| !frames.is_empty());
    let payloads: Vec<&[u8]> = match frames {
        Some(frames) => frames,
        None if looks_like_protobuf(body) => vec![body],
        None => return Err(invalid_payload()),
    };
    let mut scan = ProtoScan::default();
    let mut order = 0usize;
    for payload in payloads {
        scan_protobuf(payload, 0, &[], &mut order, &mut scan);
    }
    let mut percent = scan
        .fixed32
        .iter()
        .filter(|(path, value, _)| {
            !path.is_empty()
                && *path.last().unwrap_or(&0) == 1
                && value.is_finite()
                && (0.0..=100.0).contains(value)
        })
        .min_by_key(|(path, _, order)| (path.len(), *order))
        .map(|(_, value, _)| f64::from(*value));
    let mut resets = scan
        .varint
        .iter()
        .filter(|(_, value)| {
            (1_700_000_000..=2_100_000_000).contains(value) && (*value as i64) > now_epoch
        })
        .map(|(path, value)| (path, *value as i64))
        .collect::<Vec<_>>();
    let reset = resets
        .iter()
        .filter(|(path, _)| *path == &[1, 5, 1])
        .map(|(_, value)| *value)
        .min()
        .or_else(|| {
            resets.sort_by_key(|(_, value)| *value);
            resets.first().map(|(_, value)| *value)
        });
    let has_period = scan.varint.iter().any(|(path, value)| {
        path.starts_with(&[1, 6]) || (path == &[1, 8, 1] && matches!(value, 1 | 2))
    });
    if percent.is_none() && scan.fixed32.is_empty() && reset.is_some() && has_period {
        percent = Some(0.0);
    }
    let percent = percent.ok_or_else(invalid_payload)?;
    let (label, minutes) = grok_window(reset, now_epoch);
    Ok(Some(service_result(
        "windows",
        None,
        vec![window(label, clamp_percent(percent), minutes, reset)],
    )))
}
