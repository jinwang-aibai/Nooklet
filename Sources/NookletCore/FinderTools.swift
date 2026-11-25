import Darwin
import Foundation

public enum FinderAction: String, CaseIterable, Codable, Sendable {
    case newFolder, newFile, openTerminal
    case copyName, copyAbsolutePath, copyRelativePath, copyEscapedPath, copyFileURL
    case openWith

    public var title: String {
        switch self {
        case .newFolder: NookletLocalization.text("新建文件夹")
        case .newFile: NookletLocalization.text("新建文件")
        case .openTerminal: NookletLocalization.text("在终端打开")
        case .copyName: NookletLocalization.text("复制文件名")
        case .copyAbsolutePath: NookletLocalization.text("复制绝对路径")
        case .copyRelativePath: NookletLocalization.text("复制相对路径")
        case .copyEscapedPath: NookletLocalization.text("复制转义路径")
        case .copyFileURL: NookletLocalization.text("复制 file:// 链接")
        case .openWith: NookletLocalization.text("用应用打开")
        }
    }

    public var detail: String? {
        switch self {
        case .newFile: NookletLocalization.text("支持 .txt、.md、.json、.html 等常见格式")
        case .copyRelativePath: NookletLocalization.text("相对于用户主目录（~）")
        case .copyEscapedPath: NookletLocalization.text("适合终端命令")
        default: nil
        }
    }

    public func clipboardText(for urls: [URL], relativeTo base: URL) -> String? {
        switch self {
        case .copyName:
            urls.map(\.lastPathComponent).joined(separator: "\n")
        case .copyAbsolutePath:
            urls.map(\.path).joined(separator: "\n")
        case .copyRelativePath:
            urls.map { Self.relativePath(to: $0, from: base) }.joined(separator: "\n")
        case .copyEscapedPath:
            urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: " ")
        case .copyFileURL:
            urls.map(\.absoluteString).joined(separator: "\n")
        default:
            nil
        }
    }

    private static func relativePath(to url: URL, from base: URL) -> String {
        let target = url.standardizedFileURL.pathComponents
        let origin = base.standardizedFileURL.pathComponents
        let common = zip(target, origin).prefix { $0 == $1 }.count
        let relative = Array(repeating: "..", count: origin.count - common) + target.dropFirst(common)
        return relative.isEmpty ? "." : relative.joined(separator: "/")
    }
}

public struct FinderOpenApplication: Codable, Equatable, Sendable {
    public let url: URL
    public let name: String

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

public struct FinderToolsSettings: Codable, Sendable {
    public var enabled: Set<FinderAction> = Set(FinderAction.allCases)
    public var applications: [FinderOpenApplication] = []

    public static let userHome: URL = {
        // Foundation's current-user home can be redirected into the extension's sandbox.
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }()

    public static let store = LocalJSONStore<Self>(
        url: userHome.appending(path: "Library/Application Support/Nooklet Finder Tools.json")
    )

    public init() {}
}

public enum FinderNewFile: String, CaseIterable, Codable, Sendable {
    case text = "txt"
    case markdown = "md"
    case csv, json, yaml, yml, xml, html, css, js, ts, sh, py

    private var contents: String {
        switch self {
        case .json: "{}\n"
        case .xml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root/>\n"
        case .html: "<!doctype html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n<title></title>\n</head>\n<body>\n</body>\n</html>\n"
        default: ""
        }
    }

    public static func createFolder(in directory: URL) throws -> URL {
        try create(in: directory, name: NookletLocalization.text("未命名文件夹"), file: nil)
    }

    public func create(in directory: URL) throws -> URL {
        try Self.create(in: directory, name: NookletLocalization.text("未命名文件"), file: self)
    }

    private static func create(in directory: URL, name: String, file: Self?) throws -> URL {
        for index in 1...10_000 {
            let base = index == 1 ? name : "\(name) \(index)"
            let url = directory.appendingPathComponent(
                file.map { "\(base).\($0.rawValue)" } ?? base, isDirectory: file == nil
            )
            do {
                if let file {
                    try Data(file.contents.utf8).write(to: url, options: .withoutOverwriting)
                } else {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                }
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: directory])
    }
}

public enum FinderRequest: Codable, Sendable {
    case newFolder(URL)
    case newFile(FinderNewFile, URL)
    case openTerminal(URL)
    case openWith(FinderOpenApplication, [URL])

    private static let directory = FinderToolsSettings.store.url.deletingLastPathComponent()
        .appendingPathComponent("Nooklet Finder Requests", isDirectory: true)
    private static let fileExtension = "nooklet-finder-request"
    private static let maximumBytes = 1_048_576

    public func write() throws -> URL {
        let url = Self.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(Self.fileExtension)
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw LocalStorageError.oversizedFile(url, maximumBytes: Self.maximumBytes) }
        try LocalFile.ensureDirectory(Self.directory)
        // The host receives the URL only after the complete request has been written.
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    public static func take(at url: URL) throws -> Self? {
        guard url.isFileURL, url.pathExtension == fileExtension,
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else { return nil }
        _ = try LocalFile.existsWithoutSymlink(directory)
        let requestURL = directory.appendingPathComponent(url.lastPathComponent)
        guard let request = try LocalJSONStore<Self>(url: requestURL, maximumBytes: maximumBytes).load() else { return nil }
        try FileManager.default.removeItem(at: requestURL)
        return request.hasFileTargets ? request : nil
    }

    private var hasFileTargets: Bool {
        let targets: [URL]
        switch self {
        case .newFolder(let url), .newFile(_, let url), .openTerminal(let url): targets = [url]
        case .openWith(let app, let urls): targets = urls + [app.url]
        }
        return targets.allSatisfy { $0.isFileURL && $0.path.hasPrefix("/") }
    }
}
