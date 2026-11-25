import Darwin
import Foundation

public struct LANShareEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let isDirectory: Bool

    public init(url: URL) throws {
        let item = try LANShareItem(url: url)
        self.init(url: url.standardizedFileURL, isDirectory: item.isDirectory)
    }

    private init(url: URL, isDirectory: Bool) {
        self.id = UUID()
        self.url = url
        self.isDirectory = isDirectory
    }

    public var name: String { url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }

    func open() throws -> LANShareItem {
        let item = try LANShareItem(url: url)
        guard item.isDirectory == isDirectory else { throw LANShareError.invalidItem }
        return item
    }

    public func children(at path: [String]) throws -> [LANShareRow] {
        var folder = try open()
        for component in path { folder = try folder.child(named: component) }
        return try folder.entries()
    }

    fileprivate static func legacy(url: URL, isDirectory: Bool) -> Self {
        Self(url: url, isDirectory: isDirectory)
    }
}

public struct LANShareRow: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
}

/// The listener and link are never saved. The old single selection is migrated on read.
public struct LANShareSettings: Codable, Equatable, Sendable {
    public var entries: [LANShareEntry]
    public var text: String

    public init(entries: [LANShareEntry] = [], text: String = "") {
        self.entries = entries
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case entries, text, selection }
    private enum LegacySelection: Decodable {
        case file(URL)
        case folder(URL)
        case text(String)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decodeIfPresent([LANShareEntry].self, forKey: .entries) ?? []
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        guard !values.contains(.entries), !values.contains(.text) else { return }
        switch try values.decodeIfPresent(LegacySelection.self, forKey: .selection) {
        case .file(let url): entries = [.legacy(url: url, isDirectory: false)]
        case .folder(let url): entries = [.legacy(url: url, isDirectory: true)]
        case .text(let value): text = value
        case nil: break
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entries, forKey: .entries)
        try values.encode(text, forKey: .text)
    }
}

/// Owns an open file or directory. Child lookups are relative to a verified
/// descriptor, so a changed path or a symlink cannot redirect a request.
final class LANShareItem: Sendable {
    private static let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY
    let name: String
    let descriptor: Int32
    let size: Int64
    let isDirectory: Bool
    private let device: dev_t

    convenience init(url: URL) throws {
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else {
            throw LANShareError.invalidItem
        }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, Self.flags) } ?? -1
        }
        try self.init(descriptor: descriptor, name: url.lastPathComponent, onDevice: nil)
    }

    private init(descriptor: Int32, name: String, onDevice device: dev_t?) throws {
        guard descriptor >= 0 else { throw LANShareError.invalidItem }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              device == nil || info.st_dev == device,
              let isDirectory = Self.directoryType(info.st_mode) else {
            Darwin.close(descriptor)
            throw LANShareError.invalidItem
        }
        self.descriptor = descriptor
        self.name = name
        self.device = info.st_dev
        self.size = info.st_size
        self.isDirectory = isDirectory
    }

    deinit { Darwin.close(descriptor) }

    static func isChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(0) && !name.utf8.contains(47)
    }

    func child(named name: String) throws -> LANShareItem {
        guard isDirectory, Self.isChildName(name) else { throw LANShareError.invalidItem }
        let child = name.withCString { openat(descriptor, $0, Self.flags) }
        return try LANShareItem(descriptor: child, name: name, onDevice: device)
    }

    func entries() throws -> [LANShareRow] {
        guard isDirectory else { throw LANShareError.invalidItem }
        // Open a new directory cursor for each listing rather than sharing offsets.
        let cursor = openat(descriptor, ".", Self.flags | O_DIRECTORY)
        guard cursor >= 0 else { throw LANShareError.invalidItem }
        guard let directory = fdopendir(cursor) else {
            Darwin.close(cursor)
            throw LANShareError.invalidItem
        }
        defer { closedir(directory) }

        var entries: [LANShareRow] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name, Self.isChildName(name), !name.hasPrefix(".") else { continue }
            var info = stat()
            if name.withCString({ fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
               info.st_dev == device, let isDirectory = Self.directoryType(info.st_mode) {
                entries.append(LANShareRow(name: name, isDirectory: isDirectory, size: info.st_size))
            }
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func directoryType(_ mode: mode_t) -> Bool? {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): true
        case mode_t(S_IFREG): false
        default: nil
        }
    }
}
