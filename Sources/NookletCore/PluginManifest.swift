import Foundation

public enum PluginError: LocalizedError {
    case invalidManifest(String)
    case unsupportedSource
    case identifierMismatch
    case templateChanged
    case versionNotNewer(installed: String, incoming: String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return NookletLocalization.text("插件清单无效：%@", reason)
        case .unsupportedSource: return NookletLocalization.text("请选择 .plugin 目录或 manifest.json 文件。")
        case .identifierMismatch: return NookletLocalization.text("插件目录与清单标识不一致。")
        case .templateChanged: return NookletLocalization.text("插件更新必须保留原有模板。")
        case .versionNotNewer(let installed, let incoming):
            return NookletLocalization.text("已安装版本为 %@，导入版本 %@ 必须更新。", installed, incoming)
        }
    }
}

public enum PluginTemplate: String, CaseIterable, Sendable {
    case countdown
    case systemStatus
    case ipLookup
    case storageAnalysis
    case lanShare, menuBar, cooling, finderTools, appDiagnostics, island
    case diskEject, homebrew, runningApps, zshConfiguration
}

public struct PluginManifest: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let hostAPIVersion: Int
    public let id: String
    public let version: String
    public let name: String
    public let description: String
    public let template: String
    public let defaultDurationSeconds: Int?
    public var kind: PluginTemplate? { PluginTemplate(rawValue: template) }

    public init(
        schemaVersion: Int = 1, hostAPIVersion: Int = 1,
        id: String, version: String, name: String, description: String,
        template: String = "countdown", defaultDurationSeconds: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.hostAPIVersion = hostAPIVersion
        self.id = id
        self.version = version
        self.name = name
        self.description = description
        self.template = template
        self.defaultDurationSeconds = defaultDurationSeconds
    }

    public func validate() throws {
        guard schemaVersion == 1, hostAPIVersion == 1 else {
            throw PluginError.invalidManifest(NookletLocalization.text("需要 schemaVersion=1 和 hostAPIVersion=1。"))
        }
        let asciiID = id.utf8
        let isAlphanumeric: (UInt8) -> Bool = { (97...122).contains($0) || (48...57).contains($0) }
        guard (1...100).contains(asciiID.count),
              asciiID.allSatisfy({ isAlphanumeric($0) || $0 == 46 || $0 == 45 }),
              asciiID.first.map(isAlphanumeric) == true, asciiID.last.map(isAlphanumeric) == true,
              !id.contains("..") else {
            throw PluginError.invalidManifest(NookletLocalization.text("id 只允许小写字母、数字、点和连字符，首尾须为字母或数字。"))
        }
        guard PluginVersion(version) != nil else {
            throw PluginError.invalidManifest(NookletLocalization.text("version 必须是无前导零的三段数字，例如 1.0.0。"))
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, description.count <= 1000,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PluginError.invalidManifest(NookletLocalization.text("名称不能为空或包含控制字符；名称上限 80 字，描述上限 1000 字。"))
        }
        guard let kind else {
            throw PluginError.invalidManifest(NookletLocalization.text("当前宿主不支持模板 %@。", template))
        }
        if kind == .countdown {
            guard let defaultDurationSeconds, (1...86_400).contains(defaultDurationSeconds) else {
                throw PluginError.invalidManifest(NookletLocalization.text("计时时长必须在 1 至 86400 秒之间。"))
            }
        } else if defaultDurationSeconds != nil {
            throw PluginError.invalidManifest(NookletLocalization.text("只有计时器模板接受 defaultDurationSeconds。"))
        }
    }
}

struct PluginVersion: Comparable {
    let components: [Int]

    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  (part.count == 1 || part.first != "0"), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
