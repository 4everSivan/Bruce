//! 生成面板几何对拍 fixture: `tests/fixtures/geometry-parity/cases.json`。
//!
//! 用途: `apps/win/demo/win-taskbar-interaction-demo.html` 内联的几何镜像函数
//! (`// @geometry-parity:begin/end` 标注区段) 必须与
//! `runtime_core::compute_dashboard_geometry` 逐字段一致 —— 维护者无 Windows 机器时,
//! Demo 是人眼核验任务栏四方向自适应的唯一载体, 一旦与实现漂移, 核验即失效。
//! 同一份 fixture 被双侧读取互为守门人:
//!   - Rust: `tests/runtime_coverage.rs::dashboard_geometry_parity_fixture_is_current`
//!   - Node: `apps/win/tests/geometry-parity.test.mjs`
//!
//! 重新生成 (几何改动后必须执行, 否则双侧测试红):
//! ```zsh
//! CARGO_HOME=$PWD/local/c009/cargo-home \
//!   cargo run --manifest-path apps/win/src-tauri/Cargo.toml --no-default-features \
//!   --example dump_geometry > tests/fixtures/geometry-parity/cases.json
//! ```

use bruce_win_lib::runtime_core::{
    compute_dashboard_geometry, detect_taskbar_edge, DashboardGeometry, MonitorBounds, TaskbarEdge,
    TrayIconBounds,
};
use serde::Serialize;

#[derive(Serialize)]
struct Case {
    name: String,
    monitor: MonitorBounds,
    tray: Option<TrayIconBounds>,
    edge: TaskbarEdge,
    geometry: DashboardGeometry,
}

fn edge_name(edge: TaskbarEdge) -> &'static str {
    match edge {
        TaskbarEdge::Bottom => "bottom",
        TaskbarEdge::Top => "top",
        TaskbarEdge::Left => "left",
        TaskbarEdge::Right => "right",
    }
}

/// 该分辨率下任务栏停靠指定边时的工作区。
fn monitor(width: u32, height: u32, bar: u32, edge: TaskbarEdge, scale: f64) -> MonitorBounds {
    let (work_x, work_y, work_width, work_height) = match edge {
        TaskbarEdge::Bottom => (0, 0, width, height - bar),
        TaskbarEdge::Top => (0, bar as i32, width, height - bar),
        TaskbarEdge::Left => (bar as i32, 0, width - bar, height),
        TaskbarEdge::Right => (0, 0, width - bar, height),
    };
    MonitorBounds {
        x: 0,
        y: 0,
        width,
        height,
        work_x,
        work_y,
        work_width,
        work_height,
        scale_factor: scale,
    }
}

/// 托盘图标位于该任务栏的托盘角落: 水平栏右端 / 纵栏底端。
fn tray(width: u32, height: u32, bar: u32, edge: TaskbarEdge) -> TrayIconBounds {
    let (x, y) = match edge {
        TaskbarEdge::Bottom | TaskbarEdge::Right => {
            (width as i32 - bar as i32, height as i32 - bar as i32)
        }
        TaskbarEdge::Top => (width as i32 - bar as i32, 0),
        TaskbarEdge::Left => (0, height as i32 - bar as i32),
    };
    TrayIconBounds {
        x,
        y,
        width: bar,
        height: bar,
    }
}

fn push(cases: &mut Vec<Case>, name: String, monitor: MonitorBounds, tray: Option<TrayIconBounds>) {
    let edge = detect_taskbar_edge(&monitor, tray.as_ref());
    let geometry = compute_dashboard_geometry(&monitor, tray.as_ref());
    cases.push(Case {
        name,
        monitor,
        tray,
        edge,
        geometry,
    });
}

fn main() {
    let mut cases = Vec::new();

    // 1. 五档分辨率/DPI (与 Demo 档位一致) × 四方向 × 有/无托盘坐标
    let profiles = [
        ("1080p_100", 1920_u32, 1080_u32, 40_u32, 1.0_f64),
        ("1080p_150", 1920, 1080, 48, 1.5),
        ("768p_100", 1366, 768, 40, 1.0),
        ("2k_125", 2560, 1440, 50, 1.25),
        ("4k_200", 3840, 2160, 80, 2.0),
    ];
    for (label, width, height, bar, scale) in profiles {
        for edge in [
            TaskbarEdge::Bottom,
            TaskbarEdge::Top,
            TaskbarEdge::Left,
            TaskbarEdge::Right,
        ] {
            let m = monitor(width, height, bar, edge, scale);
            push(
                &mut cases,
                format!("{label}/{}/tray", edge_name(edge)),
                m,
                Some(tray(width, height, bar, edge)),
            );
            push(
                &mut cases,
                format!("{label}/{}/no_tray", edge_name(edge)),
                m,
                None,
            );
        }
    }

    // 2. 竖屏副屏 + 纵向任务栏
    let portrait = monitor(1080, 1920, 48, TaskbarEdge::Right, 1.0);
    push(
        &mut cases,
        "portrait/right/tray".to_owned(),
        portrait,
        Some(tray(1080, 1920, 48, TaskbarEdge::Right)),
    );
    push(
        &mut cases,
        "portrait/right/no_tray".to_owned(),
        portrait,
        None,
    );

    // 3. 自动隐藏任务栏 (工作区 == 显示器, 四边无内缩) 由托盘贴边方向推断
    let auto_hide = MonitorBounds {
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
        work_x: 0,
        work_y: 0,
        work_width: 1920,
        work_height: 1080,
        scale_factor: 1.0,
    };
    push(
        &mut cases,
        "auto_hide/bottom_tray".to_owned(),
        auto_hide,
        Some(TrayIconBounds {
            x: 1820,
            y: 1030,
            width: 40,
            height: 40,
        }),
    );
    push(
        &mut cases,
        "auto_hide/right_tray".to_owned(),
        auto_hide,
        Some(TrayIconBounds {
            x: 1870,
            y: 600,
            width: 44,
            height: 40,
        }),
    );
    push(&mut cases, "auto_hide/no_tray".to_owned(), auto_hide, None);

    // 4. 第三方 appbar/dock 与真任务栏共存: 同一份内缩几何仅凭托盘位置消歧
    let dual = MonitorBounds {
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
        work_x: 40,
        work_y: 0,
        work_width: 1880,
        work_height: 1032,
        scale_factor: 1.0,
    };
    push(
        &mut cases,
        "dual_appbar/bottom_taskbar".to_owned(),
        dual,
        Some(TrayIconBounds {
            x: 1820,
            y: 1032,
            width: 40,
            height: 40,
        }),
    );
    push(
        &mut cases,
        "dual_appbar/left_taskbar".to_owned(),
        dual,
        Some(TrayIconBounds {
            x: 4,
            y: 900,
            width: 32,
            height: 32,
        }),
    );
    push(&mut cases, "dual_appbar/no_tray".to_owned(), dual, None);

    // 5. 陈旧托盘坐标 (任务栏换屏后沿用上次 rect) 必须被丢弃, 回落贴角兜底
    push(
        &mut cases,
        "stale_tray/other_monitor".to_owned(),
        monitor(1920, 1080, 40, TaskbarEdge::Bottom, 1.0),
        Some(TrayIconBounds {
            x: -3000,
            y: 1050,
            width: 40,
            height: 40,
        }),
    );

    // 6. 副屏负坐标 + 右侧任务栏
    push(
        &mut cases,
        "negative_origin/right_taskbar".to_owned(),
        MonitorBounds {
            x: -1920,
            y: 0,
            width: 1920,
            height: 1080,
            work_x: -1920,
            work_y: 0,
            work_width: 1872,
            work_height: 1080,
            scale_factor: 1.0,
        },
        Some(TrayIconBounds {
            x: -48,
            y: 1020,
            width: 48,
            height: 40,
        }),
    );

    let fixture = serde_json::json!({
        "$comment": "面板几何对拍 fixture: 由 apps/win/src-tauri/examples/dump_geometry.rs 生成; demo 内联镜像与 Rust compute_dashboard_geometry 双侧校验, 几何改动后必须重新生成",
        "cases": cases,
    });
    println!(
        "{}",
        serde_json::to_string_pretty(&fixture).expect("fixture 序列化")
    );
}
