import Foundation

/// 额度窗口边界唤醒策略 (C037): 定时刷新不得跨过未来的额度窗口重置时刻。
///
/// 背景: 订阅刷新间隔 (默认 1800s) 与窗口重置时刻无关, 槽/窗口边界过后至下次定时刷新
/// 之间 (最长一个间隔) 卡片仍展示上一窗口的百分比并把倒计时写成「刷新中」。
///
/// 三道防线杜绝刷新风暴 —— ①只认严格在未来的边界 (滚动窗口的滑出时刻前移时天然不触发);
/// ②同一「边界值」只消费一次 (epoch 秒精确去重); ③未命中边界则回落原间隔。
///
/// 纯函数, 与 Windows 侧 `runtime_core::boundary_wake` 同构 (双端同一策略)。
package enum SubscriptionBoundaryWakePolicy {
    /// 边界是预测值, 提前量留出刷新耗时。
    package static let slack: TimeInterval = 20

    /// 从 artifact 的 `services[].windows[].resetsAt` 提取重置时刻 (epoch 秒, 与卡片同源)。
    package static func boundaries(in artifact: JSONValue) -> [Int64] {
        guard let services = artifact.objectValue?["services"]?.arrayValue else {
            return []
        }
        var result: [Int64] = []
        for service in services {
            guard let object = service.objectValue,
                  object["kind"]?.stringValue == "windows",
                  let windows = object["windows"]?.arrayValue else { continue }
            for window in windows {
                guard let entry = window.objectValue,
                      let raw = entry["resetsAt"] else { continue }
                if let epoch = raw.intValue.map(Int64.init) ?? raw.doubleValue.map(Int64.init) {
                    result.append(epoch)
                }
            }
        }
        return result
    }

    /// 下次唤醒间隔 (秒): min(间隔剩余, 最近一个未来边界 + slack)。命中时消费该边界。
    package static func delay(
        intervalRemaining: TimeInterval,
        boundaries: [Int64],
        now: Date,
        slack: TimeInterval = SubscriptionBoundaryWakePolicy.slack,
        consumed: inout Set<Int64>
    ) -> TimeInterval {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        // 已进入过去的边界不再需要记忆, 顺带收敛集合规模。
        consumed = consumed.filter { $0 > nowEpoch }

        var best: (delay: TimeInterval, boundary: Int64)?
        for boundary in boundaries where boundary > nowEpoch && !consumed.contains(boundary) {
            let delay = max(0, Double(boundary) + slack - now.timeIntervalSince1970)
            guard delay < intervalRemaining else { continue }
            if best == nil || delay < best!.delay {
                best = (delay, boundary)
            }
        }

        guard let chosen = best else { return intervalRemaining }
        consumed.insert(chosen.boundary)
        return chosen.delay
    }
}
