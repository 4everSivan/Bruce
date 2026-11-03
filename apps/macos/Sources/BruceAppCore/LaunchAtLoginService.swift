import Foundation
import ServiceManagement

/// 开机自启动在系统登录项中的状态 (12-开机自启动.md §4.2 R1)
public enum LaunchAtLoginStatus: Equatable, Sendable {
    /// 已在系统登录项中注册并启用
    case enabled
    /// 未注册为自启动项
    case notRegistered
    /// 用户在 macOS「系统设置 → 登录项」中禁用，需要人工前往系统设置允许
    case requiresApproval
    /// 当前运行环境不可用（如非 Bundle / 调试开发模式）
    case unavailable(String)

    /// 当前是否处于开启态
    public var isEnabled: Bool {
        self == .enabled
    }

    /// 是否被系统拦截需要用户前往系统设置
    public var needsApproval: Bool {
        self == .requiresApproval
    }
}

/// 开机自启动服务抽象协议 (12-开机自启动.md §4.2 R1)
public protocol LaunchAtLoginServiceProtocol: AnyObject, Sendable {
    /// 查询当前系统登录项中的自启动状态
    var status: LaunchAtLoginStatus { get }
    /// 注册开机自启动
    func register() throws
    /// 注销开机自启动
    func unregister() throws
    /// 打开 macOS「系统设置 → 通用 → 登录项与扩展」
    func openSystemSettings()
}

/// macOS 原生 ServiceManagement 开机自启动实现
public final class SystemLaunchAtLoginService: LaunchAtLoginServiceProtocol, @unchecked Sendable {
    public init() {}

    public var status: LaunchAtLoginStatus {
        let appServiceStatus = SMAppService.mainApp.status
        switch appServiceStatus {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable("未找到可注册的应用包")
        @unknown default:
            return .notRegistered
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// 用于测试与预览的模拟开机自启动服务
public final class MockLaunchAtLoginService: LaunchAtLoginServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LaunchAtLoginStatus
    private var _registerCallCount = 0
    private var _unregisterCallCount = 0
    private var _openSettingsCallCount = 0
    public var shouldThrowOnRegister: Error?
    public var shouldThrowOnUnregister: Error?

    public init(status: LaunchAtLoginStatus = .notRegistered) {
        self._status = status
    }

    public var status: LaunchAtLoginStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public var registerCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _registerCallCount
    }

    public var unregisterCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _unregisterCallCount
    }

    public var openSettingsCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _openSettingsCallCount
    }

    public func setStatus(_ newStatus: LaunchAtLoginStatus) {
        lock.lock()
        defer { lock.unlock() }
        _status = newStatus
    }

    public func register() throws {
        lock.lock()
        _registerCallCount += 1
        let error = shouldThrowOnRegister
        lock.unlock()

        if let error {
            throw error
        }
        lock.lock()
        _status = .enabled
        lock.unlock()
    }

    public func unregister() throws {
        lock.lock()
        _unregisterCallCount += 1
        let error = shouldThrowOnUnregister
        lock.unlock()

        if let error {
            throw error
        }
        lock.lock()
        _status = .notRegistered
        lock.unlock()
    }

    public func openSystemSettings() {
        lock.lock()
        _openSettingsCallCount += 1
        lock.unlock()
    }
}
