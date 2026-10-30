//! 看板与预览卡的屏幕几何: 任务栏边缘判定、贴托盘定位与尺寸夹取; C128 由 runtime_core.rs 拆出。

/// 屏幕物理边界与工作区几何信息 (解耦 Tauri GUI 依赖，便于纯单测)。
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct MonitorBounds {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub work_x: i32,
    pub work_y: i32,
    pub work_width: u32,
    pub work_height: u32,
    pub scale_factor: f64,
}

/// 托盘图标在屏幕中的物理坐标与尺寸。
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TrayIconBounds {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// 最终计算出的面板物理尺寸与位置。
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DashboardGeometry {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

fn point_in_monitor(m: &MonitorBounds, px: i32, py: i32) -> bool {
    px >= m.x && px < m.x + m.width as i32 && py >= m.y && py < m.y + m.height as i32
}

/// 看板唤出来源 (C099): 决定目标显示器与托盘锚点的取舍。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DashboardOpenSource {
    /// 托盘左键 / 托盘菜单: 面板贴托盘弹出。
    Tray,
    /// 全局热键: 面板在光标所在屏弹出 (对齐 mac 面板随活动屏菜单栏出现)。
    Hotkey,
}

/// 看板弹出位置: 目标显示器下标 (`None` 由调用方回退 `current_monitor` / `primary_monitor`)
/// 与参与几何计算的托盘锚点。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DashboardPlacement {
    pub monitor_index: Option<usize>,
    pub tray_anchor: Option<TrayIconBounds>,
}

/// 选择看板弹出位置 (C099)：
/// - 托盘唤出优先取托盘所在屏, 热键唤出优先取光标所在屏, 各自以另一方兜底;
/// - 托盘锚点只用于托盘所在屏 —— 别屏按该屏任务栏角落贴靠, 不借用另一块屏上的托盘坐标;
/// - 均未命中时不改变托盘锚点, 由调用方回退当前 / 主显示器。
pub fn select_dashboard_placement(
    monitors: &[MonitorBounds],
    tray: Option<&TrayIconBounds>,
    cursor: Option<(i32, i32)>,
    source: DashboardOpenSource,
) -> DashboardPlacement {
    let tray = tray.copied().filter(|t| t.width > 0 && t.height > 0);
    let tray_monitor =
        tray.and_then(|t| monitors.iter().position(|m| point_in_monitor(m, t.x, t.y)));
    let cursor_monitor =
        cursor.and_then(|(cx, cy)| monitors.iter().position(|m| point_in_monitor(m, cx, cy)));
    let monitor_index = match source {
        DashboardOpenSource::Tray => tray_monitor.or(cursor_monitor),
        DashboardOpenSource::Hotkey => cursor_monitor.or(tray_monitor),
    };
    let tray_anchor = if monitor_index.is_none() || monitor_index == tray_monitor {
        tray
    } else {
        None
    };
    DashboardPlacement {
        monitor_index,
        tray_anchor,
    }
}

/// 任务栏停靠边 (Windows 任务栏可置于屏幕四边任意一侧)。
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskbarEdge {
    Bottom,
    Top,
    Left,
    Right,
}

impl TaskbarEdge {
    /// 任务栏水平 (沿屏幕宽方向铺满) 时为 true。
    pub fn is_horizontal(self) -> bool {
        matches!(self, TaskbarEdge::Bottom | TaskbarEdge::Top)
    }
}

/// 消歧与兜底的优先顺序: Windows 任务栏默认停靠底部, 右侧次之。
const EDGE_PRIORITY: [TaskbarEdge; 4] = [
    TaskbarEdge::Bottom,
    TaskbarEdge::Right,
    TaskbarEdge::Top,
    TaskbarEdge::Left,
];

/// 工作区相对显示器边界的内缩量 (物理像素): (left, top, right, bottom)。
/// 任务栏所在边留下正内缩; 四边皆为 0 表示任务栏自动隐藏或不存在。
fn work_insets(monitor: &MonitorBounds) -> (i32, i32, i32, i32) {
    let left = (monitor.work_x - monitor.x).max(0);
    let top = (monitor.work_y - monitor.y).max(0);
    let mon_right = monitor.x + monitor.width as i32;
    let mon_bottom = monitor.y + monitor.height as i32;
    let work_right = monitor.work_x + monitor.work_width as i32;
    let work_bottom = monitor.work_y + monitor.work_height as i32;
    let right = (mon_right - work_right).max(0);
    let bottom = (mon_bottom - work_bottom).max(0);
    (left, top, right, bottom)
}

/// 任务栏在该边的物理矩形 (工作区之外的那条带状区域)。
/// 相邻两边的条带互不重叠: 底边条带止于 work_right, 左边条带止于 work_bottom —
/// 这样托盘落在左下角时不会同时命中「底任务栏」与「左侧第三方工具条」。
fn bar_rect(monitor: &MonitorBounds, edge: TaskbarEdge) -> (i32, i32, i32, i32) {
    let mon_left = monitor.x;
    let mon_top = monitor.y;
    let mon_right = monitor.x + monitor.width as i32;
    let mon_bottom = monitor.y + monitor.height as i32;
    let work_left = monitor.work_x;
    let work_top = monitor.work_y;
    let work_right = monitor.work_x + monitor.work_width as i32;
    let work_bottom = monitor.work_y + monitor.work_height as i32;
    match edge {
        TaskbarEdge::Bottom => (mon_left, work_bottom, work_right, mon_bottom),
        TaskbarEdge::Top => (mon_left, mon_top, work_right, work_top),
        TaskbarEdge::Left => (mon_left, mon_top, work_left, work_bottom),
        TaskbarEdge::Right => (work_right, mon_top, mon_right, work_bottom),
    }
}

/// 半开区间命中判定。
fn rect_contains(rect: (i32, i32, i32, i32), x: i32, y: i32) -> bool {
    let (left, top, right, bottom) = rect;
    x >= left && x < right && y >= top && y < bottom
}

fn rect_center(rect: &TrayIconBounds) -> (i32, i32) {
    (
        rect.x + rect.width as i32 / 2,
        rect.y + rect.height as i32 / 2,
    )
}

/// 四边均无内缩 (任务栏自动隐藏/隐藏) 时，按托盘贴边方向推断任务栏边。
fn edge_nearest_tray(monitor: &MonitorBounds, tray: &TrayIconBounds) -> Option<TaskbarEdge> {
    let (cx, cy) = rect_center(tray);
    let mon_right = monitor.x + monitor.width as i32;
    let mon_bottom = monitor.y + monitor.height as i32;
    // 托盘 rect 可能退化为点击点位, 带宽取托盘尺寸与屏幕尺寸 2.5% 的较大者
    let band_x = (tray.width as i32).max((monitor.width as i32 / 40).max(8));
    let band_y = (tray.height as i32).max((monitor.height as i32 / 40).max(8));
    for edge in EDGE_PRIORITY {
        let hit = match edge {
            TaskbarEdge::Bottom => mon_bottom - cy <= band_y,
            TaskbarEdge::Top => cy - monitor.y <= band_y,
            TaskbarEdge::Left => cx - monitor.x <= band_x,
            TaskbarEdge::Right => mon_right - cx <= band_x,
        };
        if hit {
            return Some(edge);
        }
    }
    None
}

/// 判定任务栏停靠边。
///
/// 1. 工作区内缩给出候选边; 托盘 rect 落在哪条候选任务栏条带内即为该边
///    (第三方 appbar/dock 与真任务栏共存时唯一可靠的消歧信号);
/// 2. 四边均无内缩 (自动隐藏/无任务栏) 时按托盘贴边方向推断;
/// 3. 仍无结论时按 Windows 默认停靠顺序 (底 > 右 > 上 > 左) 兜底。
pub fn detect_taskbar_edge(monitor: &MonitorBounds, tray: Option<&TrayIconBounds>) -> TaskbarEdge {
    let (left, top, right, bottom) = work_insets(monitor);
    let inset_of = |edge: TaskbarEdge| match edge {
        TaskbarEdge::Bottom => bottom,
        TaskbarEdge::Top => top,
        TaskbarEdge::Left => left,
        TaskbarEdge::Right => right,
    };

    if let Some(t) = tray {
        let (cx, cy) = rect_center(t);
        for edge in EDGE_PRIORITY.iter().copied().filter(|e| inset_of(*e) > 0) {
            let (l, t0, r, b) = bar_rect(monitor, edge);
            // 容差 1px: 托盘 rect 与条带边界相切时仍视为命中
            if rect_contains((l - 1, t0 - 1, r + 1, b + 1), cx, cy) {
                return edge;
            }
        }
        if left + top + right + bottom == 0 {
            if let Some(edge) = edge_nearest_tray(monitor, t) {
                return edge;
            }
        }
    }

    for edge in EDGE_PRIORITY {
        if inset_of(edge) > 0 {
            return edge;
        }
    }
    TaskbarEdge::Bottom
}

/// 托盘 rect 可信性校验: 陈旧坐标 (任务栏换边/换屏后沿用上次 rect) 与检测出的任务栏边
/// 不一致时丢弃, 交由贴角兜底, 避免把面板锚到别的显示器或屏幕另一端。
fn usable_tray<'a>(
    monitor: &MonitorBounds,
    edge: TaskbarEdge,
    tray: Option<&'a TrayIconBounds>,
) -> Option<&'a TrayIconBounds> {
    let t = tray?;
    let (left, top, right, bottom) = work_insets(monitor);
    if left + top + right + bottom == 0 {
        // 无任务栏内缩: 边本身由托盘推断而来, 直接采用
        return Some(t);
    }
    let (l, t0, r, b) = bar_rect(monitor, edge);
    let (cx, cy) = rect_center(t);
    if rect_contains((l, t0, r, b), cx, cy) {
        Some(t)
    } else {
        None
    }
}

/// 自适应尺寸: 宽度基准 440 逻辑px、高度基准 760 逻辑px，依次受工作区宽/高与 DPI 缩放约束。
fn compute_size(monitor: &MonitorBounds, scale: f64) -> (u32, u32) {
    let base_logical_w = 440.0_f64;
    let max_logical_w = (monitor.work_width as f64 / scale - 16.0).max(240.0);
    let target_logical_w = base_logical_w.min(max_logical_w);
    let win_w = ((target_logical_w * scale).round() as u32).min(monitor.work_width);

    let base_logical_h = 760.0_f64;
    let avail_logical_h = monitor.work_height as f64 / scale;
    // 上下各预留 10px 边距 (共 20px)，最小保障 320px
    let max_logical_h = (avail_logical_h - 20.0).max(320.0);
    let target_logical_h = base_logical_h.min(max_logical_h);
    let win_h = ((target_logical_h * scale).round() as u32).min(monitor.work_height);
    (win_w, win_h)
}

/// 夹紧到含边距的舒适区间; 工作区不足以同时容纳两侧边距时退化为硬边界 (面板仍不越出工作区)。
fn clamp_axis(target: i32, comfort_lo: i32, comfort_hi: i32, hard_lo: i32, hard_hi: i32) -> i32 {
    if comfort_lo <= comfort_hi {
        target.clamp(comfort_lo, comfort_hi)
    } else {
        target.clamp(hard_lo, hard_hi.max(hard_lo))
    }
}

/// 纯函数：根据显示器物理工作区、DPI 缩放与托盘图标 Rect，计算自适应看板物理尺寸与贴靠坐标。
///
/// 四边统一模型 (Windows 任务栏可停靠屏幕四边):
/// 1. 判边：由 `work_area` 内缩定位任务栏所在边，托盘 rect 用于消歧 (`detect_taskbar_edge`)；
/// 2. 贴边：面板恒贴任务栏内侧 (水平 12 / 垂直 10 逻辑px 边距)，绝不越入工作区之外；
/// 3. 对齐：沿任务栏轴向居中于托盘图标；无可用托盘坐标时贴托盘所在角落 (右/下)，再夹紧到工作区；
/// 4. 尺寸：1080p 150%、1366x768 等小屏/高缩放下自动降低高度，保证底栏齿轮/退出按钮完整可见。
pub fn compute_dashboard_geometry(
    monitor: &MonitorBounds,
    tray: Option<&TrayIconBounds>,
) -> DashboardGeometry {
    let scale = if monitor.scale_factor > 0.0 {
        monitor.scale_factor
    } else {
        1.0
    };

    let (win_w, win_h) = compute_size(monitor, scale);
    let (win_w, win_h) = (win_w as i32, win_h as i32);

    let margin_x = ((12.0 * scale).round() as i32).max(4);
    let margin_y = ((10.0 * scale).round() as i32).max(4);

    let work_left = monitor.work_x;
    let work_top = monitor.work_y;
    let work_right = monitor.work_x + monitor.work_width as i32;
    let work_bottom = monitor.work_y + monitor.work_height as i32;

    let edge = detect_taskbar_edge(monitor, tray);
    let anchor = usable_tray(monitor, edge, tray).map(rect_center);

    // 贴边轴: 面板紧贴任务栏内侧; 对齐轴: 居中于托盘, 无托盘坐标时贴托盘所在角落
    let (target_x, target_y) = match edge {
        TaskbarEdge::Bottom => (
            anchor.map_or(work_right - margin_x - win_w, |(cx, _)| cx - win_w / 2),
            work_bottom - margin_y - win_h,
        ),
        TaskbarEdge::Top => (
            anchor.map_or(work_right - margin_x - win_w, |(cx, _)| cx - win_w / 2),
            work_top + margin_y,
        ),
        TaskbarEdge::Left => (
            work_left + margin_x,
            anchor.map_or(work_bottom - margin_y - win_h, |(_, cy)| cy - win_h / 2),
        ),
        TaskbarEdge::Right => (
            work_right - margin_x - win_w,
            anchor.map_or(work_bottom - margin_y - win_h, |(_, cy)| cy - win_h / 2),
        ),
    };

    let x = clamp_axis(
        target_x,
        work_left + margin_x,
        work_right - margin_x - win_w,
        work_left,
        work_right - win_w,
    );
    let y = clamp_axis(
        target_y,
        work_top + margin_y,
        work_bottom - margin_y - win_h,
        work_top,
        work_bottom - win_h,
    );

    DashboardGeometry {
        x,
        y,
        width: win_w as u32,
        height: win_h as u32,
    }
}

/// 计算微缩实时预览卡 (方案 1 preview 窗口, 420x260) 的自适应几何贴靠位置
pub fn compute_preview_geometry(
    monitor: &MonitorBounds,
    tray: Option<&TrayIconBounds>,
) -> DashboardGeometry {
    compute_preview_geometry_custom(monitor, tray, 420.0, 260.0)
}

/// 计算微缩浮层 (预览卡 / 配额预警卡) 的自适应几何贴靠位置
pub fn compute_preview_geometry_custom(
    monitor: &MonitorBounds,
    tray: Option<&TrayIconBounds>,
    width_pt: f64,
    height_pt: f64,
) -> DashboardGeometry {
    let scale = if monitor.scale_factor > 0.0 {
        monitor.scale_factor
    } else {
        1.0
    };

    let win_w = ((width_pt * scale).round() as u32).min(monitor.work_width);
    let win_h = ((height_pt * scale).round() as u32).min(monitor.work_height);
    let (win_w, win_h) = (win_w as i32, win_h as i32);

    let margin_x = ((12.0 * scale).round() as i32).max(4);
    let margin_y = ((8.0 * scale).round() as i32).max(4);

    let work_left = monitor.work_x;
    let work_top = monitor.work_y;
    let work_right = monitor.work_x + monitor.work_width as i32;
    let work_bottom = monitor.work_y + monitor.work_height as i32;

    let edge = detect_taskbar_edge(monitor, tray);
    let anchor = usable_tray(monitor, edge, tray).map(rect_center);

    let (target_x, target_y) = match edge {
        TaskbarEdge::Bottom => (
            anchor.map_or(work_right - margin_x - win_w, |(cx, _)| cx - win_w / 2),
            work_bottom - margin_y - win_h,
        ),
        TaskbarEdge::Top => (
            anchor.map_or(work_right - margin_x - win_w, |(cx, _)| cx - win_w / 2),
            work_top + margin_y,
        ),
        TaskbarEdge::Left => (
            work_left + margin_x,
            anchor.map_or(work_bottom - margin_y - win_h, |(_, cy)| cy - win_h / 2),
        ),
        TaskbarEdge::Right => (
            work_right - margin_x - win_w,
            anchor.map_or(work_bottom - margin_y - win_h, |(_, cy)| cy - win_h / 2),
        ),
    };

    let x = clamp_axis(
        target_x,
        work_left + margin_x,
        work_right - margin_x - win_w,
        work_left,
        work_right - win_w,
    );
    let y = clamp_axis(
        target_y,
        work_top + margin_y,
        work_bottom - margin_y - win_h,
        work_top,
        work_bottom - win_h,
    );

    DashboardGeometry {
        x,
        y,
        width: win_w as u32,
        height: win_h as u32,
    }
}
