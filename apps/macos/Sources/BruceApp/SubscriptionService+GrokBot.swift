import BruceAppCore
import BruceOnboardingCore
import Foundation

@MainActor
extension SubscriptionService {
    /// Grok Bot (T39, design/02 规则 18): 绑定客户端当前登录的账号 (用户点击触发).
    ///
    /// 只读 `client-meta.account-slot` 取账号标识, 不读加密会话与钥匙串. 单账号语义:
    /// 重新连接替换旧绑定, 旧服务 ID 随之消失, 旧读数不会被另一账号沿用.
    func connectGrokBot() {
        let dataDirectory = GrokBotLocalClient.defaultDataDirectory(homeURL: homeURL)
        let account: String
        switch GrokBotLocalClient.readActiveAccount(dataDirectory: dataDirectory) {
        case .failure(let error):
            model.setSettingsError(error.message, for: .grokBot)
            return
        case .success(nil):
            model.setSettingsError(
                "未检测到 Grok Bot 登录态, 请先打开 Grok Bot 并登录", for: .grokBot
            )
            return
        case .success(let value?):
            account = value
        }

        let accountID = GrokBotAccountIdentity.accountKey(for: account)
        let store = accountStore(for: .grokBot)
        do {
            for entry in try store.loadIndex().accounts where entry.accountID != accountID {
                try store.removeAccount(accountID: entry.accountID)
            }
        } catch {
            model.setSettingsError("Grok Bot 旧连接清理失败, 请重试", for: .grokBot)
            return
        }
        guard saveProviderAccountCredential(
            for: .grokBot,
            accountID: accountID,
            credentialJSON: account
        ) else { return }
        model.setProviderAccountSummaries((try? store.summaries()) ?? [], for: .grokBot)
        model.setSubscriptionCredentialConfigured(true, for: .grokBot)
        finishVerification(.grokBot, status: .ok)
    }
}
