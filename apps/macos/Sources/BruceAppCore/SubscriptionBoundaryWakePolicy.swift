import Foundation

/// 额度窗口边界唤醒策略 (C037): 定时刷新不得跨过未来的额度窗口重置时刻。
///
/// 背景: 订阅刷新间隔 (默认 1800s) 与窗口重置时刻无关, 槽/窗口边界过后至下次定时刷新
/// 之间 (最长一个间隔) 卡片仍展示上一窗口的百分比并把倒计时写成「刷新中」。
///
/// 三道防线杜绝刷新风暴 —— ①只认严格在未来的边界 (滚动窗口的滑出时刻前移时天然不触发);
/// ②同一「边界值」只消费一次 (epoch 秒精确去重); ③未命中边界则回落原间隔。
///
/// 规则只在共享 `collector-policy::refresh` 中实现一份 (T17); 本类型只组装请求并应用结果。
package enum SubscriptionBoundaryWakePolicy {
    /// 边界是预测值, 提前量留出刷新耗时。
    package static let slack: TimeInterval = 20

    /// 从 artifact 的 `services[].windows[].resetsAt` 提取重置时刻 (epoch 秒, 与卡片同源)。
    /// 共享入口不可用时返回空集 (不提前唤醒), 不退回本地遍历。
    package static func boundaries(in artifact: JSONValue) -> [Int64] {
        SharedRefreshPolicy.boundaries(in: artifact) ?? []
    }

    /// 下次唤醒间隔 (秒): min(间隔剩余, 最近一个未来边界 + slack)。命中时消费该边界。
    /// 共享入口不可用时回落到原间隔 (宁可不提前刷新, 也不猜测)。
    package static func delay(
        intervalRemaining: TimeInterval,
        boundaries: [Int64],
        now: Date,
        slack: TimeInterval = SubscriptionBoundaryWakePolicy.slack,
        consumed: inout Set<Int64>
    ) -> TimeInterval {
        SharedRefreshPolicy.delay(
            intervalRemaining: intervalRemaining,
            boundaries: boundaries,
            now: now,
            slack: slack,
            consumed: &consumed
        ) ?? intervalRemaining
    }
}
