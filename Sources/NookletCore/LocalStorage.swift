import Foundation

public enum LocalStorageError: LocalizedError {
    case invalidPath(URL)
    case symbolicLink(URL)
    case oversizedFile(URL, maximumBytes: Int)
    case invalidData(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let url): return NookletLocalization.text("本地路径类型不正确：%@", url.path)
        case .symbolicLink(let url): return NookletLocalization.text("为保护本地数据，不接受符号链接：%@", url.path)
        case .oversizedFile(let url, let maximumBytes):
            return NookletLocalization.text("文件超过 %@ 字节限制：%@", maximumBytes, url.lastPathComponent)
        case .invalidData(let url, let reason):
            return NookletLocalization.text("无法读取 %@，已保留原文件。%@", url.lastPathComponent, reason)
        }
    }
}

/// All application-owned data remains under this local directory.
public struct AppPaths: Sendable {
    public let rootDirectory: URL
    public var pluginsDirectory: URL { rootDirectory.appendingPathComponent("Plugins", isDirectory: true) }
    public var configurationURL: URL { rootDirectory.appendingPathComponent("configuration.json") }
    public var generalPreferencesURL: URL { rootDirectory.appendingPathComponent("general.json") }
    public var countdownURL: URL { rootDirectory.appendingPathComponent("countdown.json") }

    public init(rootDirectory: URL? = nil) throws {
        if let rootDirectory {
            guard rootDirectory.isFileURL else { throw LocalStorageError.invalidPath(rootDirectory) }
            self.rootDirectory = rootDirectory.standardizedFileURL
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let current = support.appendingPathComponent("Nooklet", isDirectory: true)
            let legacy = support.appendingPathComponent("LiteBox", isDirectory: true)
            if try !LocalFile.existsWithoutSymlink(current), try LocalFile.existsWithoutSymlink(legacy) {
                self.rootDirectory = legacy
            } else {
                self.rootDirectory = current
            }
        }
    }

    public func ensureDirectories() throws {
        try LocalFile.ensureDirectory(rootDirectory)
        try LocalFile.ensureDirectory(pluginsDirectory)
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var selectedPluginID: String?

    public init(selectedPluginID: String? = nil) {
        self.selectedPluginID = selectedPluginID
    }
}

/// Small local state files; no background flushing, polling, or network access.
/// An existing corrupt file must be handled explicitly, never silently replaced.
public struct LocalJSONStore<Value: Codable>: Sendable {
    public let url: URL
    public let maximumBytes: Int

    public init(url: URL, maximumBytes: Int = 1_048_576) {
        self.url = url
        self.maximumBytes = maximumBytes
    }

    public func load() throws -> Value? {
        guard try LocalFile.existsWithoutSymlink(url) else { return nil }
        let data = try LocalFile.read(url, maximumBytes: maximumBytes)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LocalStorageError.invalidData(url, reason: error.localizedDescription)
        }
    }

    public func save(_ value: Value) throws {
        // Validate the old file before an atomic replacement. Corruption is surfaced.
        _ = try load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw LocalStorageError.oversizedFile(url, maximumBytes: maximumBytes)
        }
        try LocalFile.ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        // The write has committed. Tighten permissions without reporting a failed write.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum LocalFile {
    static func existsWithoutSymlink(_ url: URL) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw LocalStorageError.symbolicLink(url)
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }

    static func ensureDirectory(_ url: URL) throws {
        if try existsWithoutSymlink(url) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw LocalStorageError.invalidPath(url)
            }
        } else {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, try existsWithoutSymlink(url) else {
            throw LocalStorageError.invalidPath(url)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LocalStorageError.invalidPath(url)
        }
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes, maximumBytes >= 0, maximumBytes < Int.max else {
            throw LocalStorageError.oversizedFile(url, maximumBytes: maximumBytes)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw LocalStorageError.oversizedFile(url, maximumBytes: maximumBytes)
        }
        return data
    }
}
