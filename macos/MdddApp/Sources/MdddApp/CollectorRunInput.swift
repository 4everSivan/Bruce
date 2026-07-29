import Foundation
import MdddOnboardingCore

/// 单次 Collector 运行的受控输入. 凭证只经 Bridge stdin JSON 传递,
/// 不进入命令行参数或日志.
struct CollectorRunInput: Sendable {
    let context: [String: JSONValue]
    let credentials: [String: JSONValue]
}

/// 运行输入缺失的分类错误. 区分依赖缺失和授权缺失,
/// Scheduler 据此决定走 backoff 还是 authRequired.
enum CollectorRunInputError: Error, Equatable {
    case missingDependency(module: CollectorModule, reason: String)
    case missingAuthorization(module: CollectorModule, reason: String)
}

/// 每次运行前向 Scheduler 提供受控 context 和 credentials.
@MainActor
protocol CollectorRunInputProviding {
    func runInput(for module: CollectorModule) throws -> CollectorRunInput
}

/// 基于 Onboarding 配置和 Keychain 的运行输入提供器.
/// Agent: 只授予 localSessions/localPricing 能力, 不授予 externalQuotas.
/// GitHub: 不传 token, 由 gh 官方登录态承载.
/// GitLab: 从配置读规范化 base URL, 从 Keychain 读 PAT; 两者缺失都阻止启动.
@MainActor
final class OnboardingRunInputProvider: CollectorRunInputProviding {
    private let configStore: OnboardingConfigurationStore?
    private let credentialStore: CredentialStore

    init(
        configStore: OnboardingConfigurationStore?,
        credentialStore: CredentialStore
    ) {
        self.configStore = configStore
        self.credentialStore = credentialStore
    }

    func runInput(for module: CollectorModule) throws -> CollectorRunInput {
        switch module {
        case .agentUsage:
            return CollectorRunInput(
                context: [
                    "capabilities": .array([
                        .string(CollectorCapability.localSessions.rawValue),
                        .string(CollectorCapability.localPricing.rawValue),
                    ])
                ],
                credentials: [:]
            )
        case .github:
            return CollectorRunInput(context: [:], credentials: [:])
        case .gitlab:
            return try gitLabInput()
        }
    }

    private func gitLabInput() throws -> CollectorRunInput {
        guard let rawBaseURL = configStore?.load()?.gitlabBaseURL,
              let baseURL = ProviderConnectionVerifier.normalizedGitLabBaseURL(rawBaseURL),
              let host = baseURL.host else {
            throw CollectorRunInputError.missingDependency(
                module: .gitlab,
                reason: "未配置私有 GitLab HTTPS 地址"
            )
        }
        guard let pat = try credentialStore.loadPAT(forHost: host),
              !pat.isEmpty else {
            throw CollectorRunInputError.missingAuthorization(
                module: .gitlab,
                reason: "GitLab 凭证缺失, 请在设置中重新配置 PAT"
            )
        }
        return CollectorRunInput(
            context: ["baseUrl": .string(baseURL.absoluteString)],
            credentials: ["gitlabToken": .string(pat)]
        )
    }
}
