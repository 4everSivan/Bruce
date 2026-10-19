import Foundation
import Network

// MARK: - NetworkReachabilityProviding

/// 网络可达性只读快照 + 变化回调.
///
/// 仅作为刷新调度的断网闸门, 不参与数据展示或采集结果判定.
/// 系统实现首个真实 path 更新前 fail-open (视为可用), 避免 App 启动瞬间误挡刷新.
@MainActor
package protocol NetworkReachabilityProviding: AnyObject {
    var isNetworkAvailable: Bool { get }
    var onReachabilityChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - SystemNetworkReachability

/// 基于 `NWPathMonitor` 的系统实现.
/// path 回调在串行队列上触发, 统一切回主线程后再更新状态, 保证调度器访问同源.
@MainActor
package final class SystemNetworkReachability: NetworkReachabilityProviding {
    private let queue = DispatchQueue(label: "io.bruce.network-reachability")
    private var monitor: NWPathMonitor?
    private var available = true

    package var isNetworkAvailable: Bool { available }
    package var onReachabilityChange: ((Bool) -> Void)?

    package init() {}

    package func start() {
        // 允许 stop 后再次 start (调度器自愈路径): 每次重建 monitor,
        // 因为 NWPathMonitor.cancel() 后不可复用.
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.apply(available)
            }
        }
        self.monitor = monitor
        monitor.start(queue: queue)
    }

    package func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private func apply(_ available: Bool) {
        guard available != self.available else { return }
        self.available = available
        onReachabilityChange?(available)
    }
}
