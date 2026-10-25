import Foundation

// MARK: - 软件更新数据模型 (07-软件更新 §4.2 R1 / R2 / R4)

/// 三段式语义化版本 (07 §4.2 R2): major/minor/patch 整数逐级比较, 不引第三方依赖.
/// 只接受 `X.Y.Z` (可带 `v` 前缀), 与 generate-update-manifest.mjs 的 VERSION 校验同口径;
/// 预发布后缀、缺段或非数字一律视为无效 (dev 构建降级 / 清单无效).
package struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    package let major: Int
    package let minor: Int
    package let patch: Int

    package init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    package init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Int(part) else {
                return nil
            }
            values.append(value)
        }
        self.init(major: values[0], minor: values[1], patch: values[2])
    }

    /// 不带前缀的 `X.Y.Z`.
    package var description: String { "\(major).\(minor).\(patch)" }

    /// UI 与 tag 口径 `vX.Y.Z`.
    package var tag: String { "v\(description)" }

    package static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// latest.json 原始结构 (07 §4.2 R1.1). 仅解码 macOS 用得到的字段, 其余忽略.
package struct UpdateManifest: Decodable, Sendable {
    package struct Platform: Decodable, Sendable {
        package let url: String
        package let sha256: String?
        package let signature: String?
    }

    package let version: String
    package let notes: String?
    package let platforms: [String: Platform]

    package static let darwinPlatformKey = "darwin-universal"
}

/// 发布仓库坐标: 清单直链、发布页与手动下载入口同源.
package enum UpdateRepository {
    package static let slug = "4everSivan/Bruce"
    /// Releases latest-download 直链 (07 §4.2 R1.2), 不调用 GitHub API.
    package static let manifestURL = URL(
        string: "https://github.com/\(slug)/releases/latest/download/latest.json"
    )!
    /// 「手动下载 ↗」入口.
    package static let latestReleasePageURL = URL(
        string: "https://github.com/\(slug)/releases/latest"
    )!

    package static func releasePageURL(for version: SemanticVersion) -> URL {
        URL(string: "https://github.com/\(slug)/releases/tag/\(version.tag)")!
    }
}

/// 校验后的可用版本: 清单字段经过格式与来源检查, UI 与安装器只消费此结构.
package struct UpdateRelease: Equatable, Sendable {
    package let version: SemanticVersion
    package let notes: String
    package let downloadURL: URL
    /// 小写 64 位十六进制, 与 Release SHA256SUMS 同源.
    package let sha256: String
    /// 包体字节数; 清单不含尺寸, 由检查阶段 HEAD 请求补齐, 取不到为 nil.
    package var sizeBytes: Int64?

    package init(
        version: SemanticVersion,
        notes: String,
        downloadURL: URL,
        sha256: String,
        sizeBytes: Int64? = nil
    ) {
        self.version = version
        self.notes = notes
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    package var releasePageURL: URL {
        UpdateRepository.releasePageURL(for: version)
    }

    /// 解码并校验 latest.json; 任何字段缺失或越界都按清单无效处理, 绝不带病进入下载.
    /// 下载地址限定 https://github.com, 防止被污染的清单把安装包指向第三方主机.
    package static func parse(manifestData: Data) throws -> UpdateRelease {
        guard let manifest = try? JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData
        ) else {
            throw UpdateCheckFailure.invalidManifest
        }
        guard let version = SemanticVersion(manifest.version),
              let darwin = manifest.platforms[UpdateManifest.darwinPlatformKey],
              let url = URL(string: darwin.url),
              url.scheme == "https",
              url.host?.lowercased() == "github.com",
              let sha = darwin.sha256?.lowercased(),
              sha.count == 64,
              sha.unicodeScalars.allSatisfy({
                  ("0"..."9").contains($0) || ("a"..."f").contains($0)
              }) else {
            throw UpdateCheckFailure.invalidManifest
        }
        return UpdateRelease(
            version: version,
            notes: (manifest.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            downloadURL: url,
            sha256: sha
        )
    }
}

/// 检查失败分类 (仅手动检查呈现, 自动检查静默, 07 §4.2 R5).
package enum UpdateCheckFailure: Error, Equatable, Sendable {
    /// 请求超时 (10 秒).
    case timedOut
    /// 无网络 / DNS / 连接失败.
    case offline
    /// HTTP 非 2xx.
    case httpStatus(Int)
    /// 清单无法解析或字段不合规.
    case invalidManifest
}

/// 下载与安装失败分类: 均回到 `available` 并在状态行告警 (07 §4.2 R6).
package enum UpdateInstallFailure: Error, Equatable, Sendable {
    case downloadFailed
    case checksumMismatch
    case extractFailed
    case bundleMismatch
    case versionMismatch
    case versionNotNewer
    case replaceFailed(rolledBack: Bool)
    case relaunchFailed
}

/// 下载进度 (字节).
package struct UpdateDownloadProgress: Equatable, Sendable {
    package var receivedBytes: Int64
    package var totalBytes: Int64?

    package init(receivedBytes: Int64, totalBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

/// 更新状态机 (07 §4.1 / §4.2 R4): 8 个可见态 + 安装重启过渡态.
package enum UpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case latest(checkedAt: Date)
    case available(UpdateRelease)
    case downloading(UpdateRelease, UpdateDownloadProgress)
    case ready(UpdateRelease)
    case failed(UpdateCheckFailure)
    case skipped(UpdateRelease)
    case relaunching(UpdateRelease)

    /// 导航角标: 有可用更新且未处理 (available / downloading / ready).
    package var showsNavigationBadge: Bool {
        switch self {
        case .available, .downloading, .ready:
            return true
        case .idle, .checking, .latest, .failed, .skipped, .relaunching:
            return false
        }
    }

    /// 「检查更新」按钮在检查、下载与安装重启期间禁用.
    package var allowsManualCheck: Bool {
        switch self {
        case .checking, .downloading, .relaunching:
            return false
        case .idle, .latest, .available, .ready, .failed, .skipped:
            return true
        }
    }
}
