import Darwin
import Foundation

public struct StorageItem: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let isDirectory: Bool
    public let bytes: Int64
    public let children: [StorageItem]
    public let isPartial: Bool
    public let canTrash: Bool
    fileprivate let identity: StorageIdentity
}

public struct StorageScan: Sendable {
    public let directory: URL
    public let items: [StorageItem]
    public let totalBytes: Int64
    public let fileCount: Int
    public let itemCount: Int
    public let skippedCount: Int
}

public enum StorageScanError: LocalizedError {
    case localDirectoryRequired
    case itemChanged
    case protectedItem

    public var errorDescription: String? {
        switch self {
        case .localDirectoryRequired: NookletLocalization.text("请选择本机或外接磁盘上的文件夹。")
        case .itemChanged: NookletLocalization.text("项目已移动、替换或不可访问。请重新扫描后再选择。")
        case .protectedItem: NookletLocalization.text("该项目受保护，无法移到废纸篓。")
        }
    }
}

private struct StorageIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int
    let kind: mode_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        birthSeconds = metadata.st_birthtimespec.tv_sec
        birthNanoseconds = metadata.st_birthtimespec.tv_nsec
        kind = metadata.st_mode & mode_t(S_IFMT)
    }
}

public enum StorageScanner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
    private static let protectedPaths: Set<String> = {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return Set(["/System", "/Library", "/bin", "/sbin", "/usr", "/Applications"] +
            ["Application Support", "Containers", "Group Containers"].map { library.appendingPathComponent($0).path } +
            [library.path])
    }()
    private static let homeTrash = home.appendingPathComponent(".Trash", isDirectory: true)

    /// Stream entries and retain ranked previews only within the first three levels.
    public static func scan(_ directory: URL, limit: Int = 100) throws -> StorageScan {
        try scan(directory, expected: nil, limit: limit)
    }

    public static func scan(_ item: StorageItem, limit: Int = 100) throws -> StorageScan {
        guard item.isDirectory else { throw StorageScanError.localDirectoryRequired }
        return try scan(item.url, expected: item.identity, limit: limit)
    }

    private static func scan(_ directory: URL, expected: StorageIdentity?, limit: Int) throws -> StorageScan {
        try Task.checkCancellation()
        let root = directory.resolvingSymlinksInPath()
        guard root.isFileURL, try root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal != false else {
            throw StorageScanError.localDirectoryRequired
        }
        if expected != nil, root.path != directory.path { throw StorageScanError.itemChanged }

        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let rootFD = root.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, flags) } ?? -1
        }
        guard rootFD >= 0 else { throw systemError() }
        var rootMetadata = stat()
        guard fstat(rootFD, &rootMetadata) == 0 else {
            let error = systemError()
            close(rootFD)
            throw error
        }
        if let expected, StorageIdentity(rootMetadata) != expected {
            close(rootFD)
            throw StorageScanError.itemChanged
        }
        guard let stream = fdopendir(rootFD) else {
            let error = systemError()
            close(rootFD)
            throw error
        }
        defer { closedir(stream) }

        let resultLimit = max(1, min(100, limit))
        var fileCount = 0
        var skipped = 0

        func walk(_ stream: UnsafeMutablePointer<DIR>, location: URL?, depth: Int)
        throws -> (bytes: Int64, count: Int, items: [StorageItem]) {
            let parentFD = dirfd(stream)
            let resultsAtDepth = depth == 0 ? resultLimit : 12
            var top: [StorageItem] = []
            var count = 0
            var subtotal: Int64 = 0
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 {
                        if depth == 0 { throw systemError() }
                        skipped += 1
                    }
                    return (subtotal, count, top)
                }
                let nameLength = Int(entry.pointee.d_namlen)
                let bytes = try withUnsafePointer(to: &entry.pointee.d_name) {
                    try $0.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) { name -> Int64 in
                        if name[0] == 46, nameLength == 1 || (nameLength == 2 && name[1] == 46) { return 0 }

                        var metadata = stat()
                        guard fstatat(parentFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                              metadata.st_dev == rootMetadata.st_dev else {
                            skipped += 1
                            return 0
                        }
                        let identity = StorageIdentity(metadata)
                        let isDirectory = identity.kind == mode_t(S_IFDIR)
                        guard isDirectory || identity.kind == mode_t(S_IFREG) else {
                            skipped += 1
                            return 0
                        }

                        count += 1
                        let url = location.flatMap { directory in
                            String(validatingCString: name).map { directory.appendingPathComponent($0, isDirectory: isDirectory) }
                        }
                        let previousSkipped = skipped
                        var size = min(Int64.max / 512, max(0, Int64(metadata.st_blocks))) * 512
                        var previews: [StorageItem] = []
                        if isDirectory {
                            let childFD = openat(parentFD, name, flags)
                            if childFD >= 0 {
                                var opened = stat()
                                if fstat(childFD, &opened) == 0, StorageIdentity(opened) == identity,
                                   let child = fdopendir(childFD) {
                                    defer { closedir(child) }
                                    let childResult = try walk(child, location: depth < 2 ? url : nil, depth: depth + 1)
                                    size += min(Int64.max - size, childResult.bytes)
                                    previews = childResult.items
                                } else {
                                    close(childFD)
                                    skipped += 1
                                }
                            } else {
                                skipped += 1
                            }
                        } else {
                            fileCount += 1
                        }

                        if let url, top.count < resultsAtDepth || top.last.map({ size > $0.bytes }) == true {
                            let item = StorageItem(url: url, isDirectory: isDirectory, bytes: size, children: previews,
                                                   isPartial: skipped > previousSkipped,
                                                   canTrash: !isProtected(url, metadata: metadata), identity: identity)
                            let index = top.firstIndex { size > $0.bytes } ?? top.endIndex
                            top.insert(item, at: index)
                            if top.count > resultsAtDepth { top.removeLast() }
                        }
                        return size
                    }
                }
                subtotal += min(Int64.max - subtotal, bytes)
            }
        }

        let result = try walk(stream, location: root, depth: 0)
        return StorageScan(directory: root, items: result.items, totalBytes: result.bytes, fileCount: fileCount,
                           itemCount: result.count, skippedCount: skipped)
    }

    /// Check the scanned entry before asking the system to move it to the Trash.
    public static func validateForTrash(_ item: StorageItem, in root: URL) throws {
        guard item.canTrash, isWithin(item.url, directory: root, includingDirectory: false) else {
            throw StorageScanError.protectedItem
        }
        guard item.url.resolvingSymlinksInPath().path == item.url.path else { throw StorageScanError.itemChanged }
        var metadata = stat()
        let result = item.url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &metadata) } ?? -1
        }
        guard result == 0, StorageIdentity(metadata) == item.identity else { throw StorageScanError.itemChanged }
        guard !isProtected(item.url, metadata: metadata) else { throw StorageScanError.protectedItem }
    }

    public static func isWithin(_ item: URL, directory: URL, includingDirectory: Bool = true) -> Bool {
        let path = item.standardizedFileURL.pathComponents
        let prefix = directory.standardizedFileURL.pathComponents
        return (includingDirectory || path.count > prefix.count) && path.starts(with: prefix)
    }

    private static func isProtected(_ url: URL, metadata: stat) -> Bool {
        if metadata.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_RESTRICTED) != 0 { return true }
        if protectedPaths.contains(url.path) || isWithin(url, directory: homeTrash) { return true }
        return isWithin(home, directory: url)
    }

    private static func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
