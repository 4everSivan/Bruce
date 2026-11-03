import Foundation
@testable import BruceOnboardingCore

func egressCountryGroupsTests() throws {
    guard EgressTracePresentation.describe("ip=192.0.2.1\r\nloc=JP\r\n", expected: "JP")
            == "线路探测匹配 · 192.0.***.*** (JP)",
          EgressTracePresentation.describe("ip=192.0.2.1\nloc=ZZ\n", expected: "JP")
            == "无法识别出口国家",
          EgressTracePresentation.describe("ip=bad:ip\nloc=JP\n", expected: "JP")
            == "无法识别出口地址",
          EgressTracePresentation.describe("ip=2001:db8::1\nloc=JP\n", expected: "JP")
            == "线路探测匹配 · IPv6 已隐藏 (JP)" else {
        throw TestFailure("线路测试响应解析或脱敏失败")
    }
    var groups = EgressCountryGroups()
    try groups.addCountry(" jp ")
    try groups.addCountry("US")
    guard groups.groups.map(\.country) == ["JP", "US"] else {
        throw TestFailure("国家代码应标准化")
    }
    guard groups.groups[0].flag == "🇯🇵",
          groups.groups[1].flag == "🇺🇸",
          EgressCountryGroups.flagEmoji(for: "SG") == "🇸🇬",
          EgressCountryGroups.flagEmoji(for: "gb") == "🇬🇧",
          EgressCountryGroups.flagEmoji(for: "12") == "",
          EgressCountryGroups.flagEmoji(for: "JPN") == "" else {
        throw TestFailure("国旗 Emoji 转换失败")
    }
    do {
        try groups.addCountry("JP")
        throw TestFailure("重复国家应被拒绝")
    } catch EgressCountryGroupError.duplicateCountry {}
    do {
        try groups.addCountry("ZZ")
        throw TestFailure("无效国家应被拒绝")
    } catch EgressCountryGroupError.invalidCountry {}
    do {
        try groups.addCountry("EU")
        throw TestFailure("非 ISO 国家地区码应被拒绝")
    } catch EgressCountryGroupError.invalidCountry {}

    try groups.assign(.codex, to: "JP")
    try groups.assign(.claude, to: "JP")
    try groups.setProxyPort(10809, for: "JP")
    do {
        try groups.setProxyPort(0, for: "JP")
        throw TestFailure("无效端口应被拒绝")
    } catch EgressCountryGroupError.invalidPort {}
    guard groups.groups[0].proxyPort == 10809 else {
        throw TestFailure("无效端口不得覆盖已有端口")
    }
    try groups.assign(.codex, to: "US")
    guard groups.groups[0].providers == [.claude],
          groups.groups[1].providers == [.codex] else {
        throw TestFailure("移动 provider 应同时解除原组归属")
    }
    let original = groups
    do {
        try groups.assign(.claude, to: "FR")
        throw TestFailure("不存在的国家应被拒绝")
    } catch EgressCountryGroupError.countryNotFound {}
    guard groups == original else {
        throw TestFailure("移动失败不得改变原归属")
    }
    let roundTrip = try JSONDecoder().decode(
        EgressCountryGroups.self, from: JSONEncoder().encode(groups)
    )
    guard roundTrip == groups else { throw TestFailure("分组编码往返失败") }
    var configuration = OnboardingConfiguration()
    configuration.egressGroups = groups
    let decodedConfiguration = try JSONDecoder().decode(
        OnboardingConfiguration.self, from: JSONEncoder().encode(configuration)
    )
    guard decodedConfiguration.egressGroups == groups else {
        throw TestFailure("配置应保留国家组和专用端口")
    }
    let legacy = try JSONDecoder().decode(
        OnboardingConfiguration.self, from: Data("{\"schemaVersion\":1}".utf8)
    )
    guard legacy.egressGroups.groups.isEmpty else {
        throw TestFailure("旧配置缺少国家组时应保持未分组")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("egress-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try OnboardingConfigurationStore(configDirectory: directory)
    let credentialPath = directory.appendingPathComponent("credentials.json")
    let credentialStore = ProtectedFileCredentialStore(
        fileURL: credentialPath,
        accessController: KeychainAccessController(policy: KeychainAccessPolicy(
            configuration: KeychainAccessConfiguration(bruceStoreConfigured: true)
        ))
    )
    try credentialStore.saveCredential("fixture-secret", forAccount: "fixture:account")
    let credentialsBefore = try Data(contentsOf: credentialPath)
    var old = OnboardingConfiguration(schemaVersion: 2, consentVersion: 1)
    try store.save(old)
    old.egressGroups = groups
    try store.save(old)
    var moved = old
    moved.egressGroups.remove(.codex)
    try store.save(moved)
    guard try Data(contentsOf: credentialPath) == credentialsBefore else {
        throw TestFailure("分组保存和移出不得修改凭据文件")
    }
    try store.save(OnboardingConfiguration(schemaVersion: 2, consentVersion: 1))
    try store.save(old)
    guard store.load()?.schemaVersion == 3 else {
        throw TestFailure("启用分组须升级配置版本，供旧版拒绝直接读取")
    }
    let path = directory.appendingPathComponent("onboarding-v1.json")
    let damaged = Data("{invalid".utf8)
    try damaged.write(to: path)
    guard store.load() == nil else {
        throw TestFailure("损坏的保护配置不得回滚到无保护备份")
    }
    do {
        try store.save(OnboardingConfiguration())
        throw TestFailure("损坏配置不得被默认配置覆盖")
    } catch is TestFailure {
        throw TestFailure("损坏配置不得被默认配置覆盖")
    } catch {}
    guard try Data(contentsOf: path) == damaged else {
        throw TestFailure("应保留损坏配置现场")
    }
    let duplicate = Data("""
    [{"country":"JP","providers":["codex"]},
     {"country":"US","providers":["codex"]}]
    """.utf8)
    do {
        _ = try JSONDecoder().decode(EgressCountryGroups.self, from: duplicate)
        throw TestFailure("重复 provider 应被拒绝")
    } catch EgressCountryGroupError.duplicateProvider {}
    groups.remove(.codex)
    try groups.removeCountry("JP")
    guard groups.groups.count == 1, groups.groups[0].providers.isEmpty else {
        throw TestFailure("移出与解散应仅修改分组")
    }

    // 验证 lastTestResult 持久化与编解码往返
    groups.setLastTestResult("出口国家不匹配 · 198.44.***.*** (US)", for: "US")
    guard groups.groups.first(where: { $0.country == "US" })?.lastTestResult
            == "出口国家不匹配 · 198.44.***.*** (US)" else {
        throw TestFailure("lastTestResult 设置失败")
    }
    let roundTripWithResult = try JSONDecoder().decode(
        EgressCountryGroups.self, from: JSONEncoder().encode(groups)
    )
    guard roundTripWithResult.groups.first(where: { $0.country == "US" })?.lastTestResult
            == "出口国家不匹配 · 198.44.***.*** (US)" else {
        throw TestFailure("lastTestResult 编解码往返保留失败")
    }
    // 验证修改端口时自动清除旧测试结果
    try groups.setProxyPort(8080, for: "US")
    guard groups.groups.first(where: { $0.country == "US" })?.lastTestResult == nil else {
        throw TestFailure("更改代理端口后应重置清除旧测试结果")
    }
    // 验证相同端口不清除测试结果
    groups.setLastTestResult("线路探测匹配 · 104.28.***.*** (US)", for: "US")
    try groups.setProxyPort(8080, for: "US")
    guard groups.groups.first(where: { $0.country == "US" })?.lastTestResult
            == "线路探测匹配 · 104.28.***.*** (US)" else {
        throw TestFailure("设置相同端口不应清除已有测试结果")
    }

    // 验证文案前缀契约 (供 EgressSettingsCard 状态色阶精准分流)
    let mismatchText = EgressTracePresentation.describe("ip=198.44.1.2\nloc=US\n", expected: "SG")
    guard mismatchText.hasPrefix("出口国家不匹配") else {
        throw TestFailure("预期国家与出口不符时应输出出口国家不匹配")
    }
    let matchText = EgressTracePresentation.describe("ip=198.44.1.2\nloc=US\n", expected: "US")
    guard matchText.hasPrefix("线路探测匹配") else {
        throw TestFailure("预期国家与出口相符时应输出线路探测匹配")
    }
}

private struct TestFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
