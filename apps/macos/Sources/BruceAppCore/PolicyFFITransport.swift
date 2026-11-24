import Foundation
import BruceOnboardingCore
import BrucePolicyFFI

// MARK: - 共享策略 FFI 传输层 (C263, design/08)
//
// 三个策略客户端（额度门禁/回填、额度预警、刷新策略）共用同一份
// policy-request-v1 / policy-response-v1 编解码与校验，不再各自复制：
// - 请求固定注入 schemaVersion=1 与 operation；
// - 响应必须 schemaVersion==1，error 信封只暴露首个诊断码；
// - C ABI 版本在每次进程内调用前握手，过期的 libbruce_policy.a 不得静默链接。

package enum PolicyFFITransport {
    package enum Failure: Error, Equatable {
        /// 输出不是合法的 policy-response-v1 信封。
        case invalidResponse
        /// 入口返回 error 信封（诊断码见 policy-response-v1）。
        case rejected(code: String)
        /// 静态库 ABI 版本与本端预期不一致（过期的 local/build/policy-ffi/libbruce_policy.a）。
        case abiMismatch(expected: UInt32, actual: UInt32)
    }

    /// 与 `collector-policy-ffi` 的 `ABI_VERSION`、`bruce_policy.h` 同步维护。
    package static let expectedABIVersion: UInt32 = 1

    /// 构造 policy-request-v1 请求字节。
    package static func request(
        operation: String,
        fields: [String: JSONValue]
    ) throws -> Data {
        var request = fields
        request["schemaVersion"] = .integer(1)
        request["operation"] = .string(operation)
        return try JSONEncoder().encode(JSONValue.object(request))
    }

    /// 解码并校验 policy-response-v1 信封；成功时返回 `result` 对象。
    package static func decode(_ output: Data) throws -> [String: JSONValue] {
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: output).objectValue,
              response["schemaVersion"]?.intValue == 1 else {
            throw Failure.invalidResponse
        }
        guard response["status"]?.stringIdValue == "success",
              let result = response["result"]?.objectValue else {
            let code = response["diagnostics"]?.arrayValue?.first?.objectValue?["code"]?
                .stringIdValue
            guard let code else { throw Failure.invalidResponse }
            throw Failure.rejected(code: code)
        }
        return result
    }

    /// 进程内调用 (T16)：复制并释放静态库返回的缓冲区。
    package static func inProcess(_ input: Data) throws -> Data {
        let actual = bruce_policy_abi_version()
        guard actual == expectedABIVersion else {
            throw Failure.abiMismatch(expected: expectedABIVersion, actual: actual)
        }
        var outputLength = 0
        let buffer = input.withUnsafeBytes { raw in
            bruce_policy_call(
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count,
                &outputLength
            )
        }
        guard let buffer else { return Data() }
        defer { bruce_policy_free(buffer, outputLength) }
        return Data(bytes: buffer, count: outputLength)
    }

    /// 编码 → 进程内调用 → 解码的完整入口。
    package static func call(
        operation: String,
        fields: [String: JSONValue]
    ) throws -> [String: JSONValue] {
        try decode(inProcess(try request(operation: operation, fields: fields)))
    }
}
