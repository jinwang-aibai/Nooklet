import Darwin
import Foundation
import Combine

enum BrewPackageKind: String, CaseIterable, Identifiable {
    case formula, cask

    var id: Self { self }
    var title: String { self == .formula ? "Formula" : "Cask" }
    var option: String { "--" + rawValue }
}

struct BrewPackage: Identifiable {
    let kind: BrewPackageKind
    let name: String
    var description: String?
    var homepage: URL?
    var availableVersion: String?
    var installedVersions: [String] = []
    var outdated = false

    var id: String { "\(kind.rawValue):\(name)" }

    static func validName(_ name: String) -> Bool {
        !name.hasPrefix("-") && name.wholeMatch(of: /[a-zA-Z0-9_@+.-]+(?:\/[a-zA-Z0-9_@+.-]+){0,2}/) != nil
    }
}

enum BrewPackageAction: String {
    case install, upgrade, uninstall

    var title: String {
        switch self {
        case .install: L10n.text("安装")
        case .upgrade: L10n.text("升级")
        case .uninstall: L10n.text("卸载")
        }
    }
}

enum BrewMaintenance: String, CaseIterable {
    case update, upgrade, doctor, config, previewCleanup, cleanup

    var title: String {
        switch self {
        case .update: L10n.text("更新软件源")
        case .upgrade: L10n.text("升级所有包")
        case .doctor: L10n.text("运行诊断")
        case .config: L10n.text("查看环境配置")
        case .previewCleanup: L10n.text("预览清理")
        case .cleanup: L10n.text("清理缓存")
        }
    }

    var arguments: [String] {
        switch self {
        case .previewCleanup: ["cleanup", "--dry-run"]
        default: [rawValue]
        }
    }

    var changesSystem: Bool { self == .update || self == .upgrade || self == .cleanup }
}

struct BrewLogEntry: Equatable {
    enum Kind { case command, output, success, warning, error }
    let kind: Kind
    let message: String
}

enum BrewOutcome {
    case success, warning, failure, cancelled
}

private struct BrewInventory: Decodable {
    struct Formula: Decodable {
        struct Versions: Decodable { let stable: String? }
        struct Installed: Decodable { let version: String }
        let name: String
        let full_name: String?
        let desc: String?
        let homepage: String?
        let versions: Versions?
        let installed: [Installed]?
        let outdated: Bool?

        var package: BrewPackage {
            BrewPackage(kind: .formula, name: full_name ?? name, description: desc, homepage: homepage.flatMap(URL.init(string:)),
                        availableVersion: versions?.stable, installedVersions: installed?.map(\.version) ?? [], outdated: outdated ?? false)
        }
    }

    struct Cask: Decodable {
        let token: String
        let full_token: String?
        let desc: String?
        let homepage: String?
        let version: String?
        let installed: String?
        let outdated: Bool?

        var package: BrewPackage {
            BrewPackage(kind: .cask, name: full_token ?? token, description: desc, homepage: homepage.flatMap(URL.init(string:)),
                        availableVersion: version, installedVersions: installed.map { [$0] } ?? [], outdated: outdated ?? false)
        }
    }

    let formulae: [Formula]
    let casks: [Cask]

    var packages: [BrewPackage] { formulae.map(\.package) + casks.map(\.package) }
}

private struct BrewCommandResult {
    let status: Int32
    let output: String
    let errors: String
}

private enum BrewError: LocalizedError {
    case missingExecutable, invalidPath, notHomebrew, failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable: L10n.text("未找到 Homebrew。")
        case .invalidPath: L10n.text("请输入可执行 brew 文件的绝对路径。")
        case .notHomebrew: L10n.text("所选文件未返回有效的 Homebrew 版本。")
        case .failed(let status, let output):
            output.isEmpty ? L10n.text("Homebrew 退出，状态码 %@。", status) : output
        }
    }
}

@MainActor
private final class BrewProcess {
    private var process: Process?
    private var processGroup: pid_t?
    private var escalation: Task<Void, Never>?

    func run(_ command: URL, arguments: [String], capture: Bool,
             log: @escaping @MainActor @Sendable (String, Bool) -> Void) async throws -> BrewCommandResult {
        try Task.checkCancellation()
        let child = Process()
        child.executableURL = command
        child.arguments = arguments
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([command.deletingLastPathComponent().path, environment["PATH"]]
            .compactMap { $0 } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["NONINTERACTIVE"] = "1"
        if arguments.first == "cleanup" { environment["HOMEBREW_NO_AUTOREMOVE"] = "1" }
        child.environment = environment
        child.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        child.standardOutput = stdout
        child.standardError = stderr
        let completion = AsyncStream<Int32>.makeStream()
        child.terminationHandler = { completed in
            completion.continuation.yield(completed.terminationStatus)
            completion.continuation.finish()
        }
        try child.run()
        process = child
        let pid = child.processIdentifier
        processGroup = getpgid(pid) == pid ? pid : nil
        defer {
            process = nil
            processGroup = nil
            escalation?.cancel()
            escalation = nil
        }

        let outputLog: @MainActor @Sendable (String) -> Void = { log($0, false) }
        async let output = Self.read(stdout.fileHandleForReading, capture: capture, log: capture ? nil : outputLog)
        async let errors = Self.read(stderr.fileHandleForReading, capture: false) { log($0, true) }
        // A cancelled operation still waits for the child and both pipes to finish.
        let status = await Task.detached {
            var iterator = completion.stream.makeAsyncIterator()
            return await iterator.next() ?? -1
        }.value
        return try await BrewCommandResult(status: status, output: output, errors: errors)
    }

    func cancel() {
        guard let process, escalation == nil else { return }
        let group = processGroup
        if let group { kill(-group, SIGINT) } else if process.isRunning { process.interrupt() }
        escalation = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard self.process === process else { return }
            if let group { kill(-group, SIGTERM) } else if process.isRunning { process.terminate() }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard self.process === process else { return }
            if let group { kill(-group, SIGKILL) } else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    nonisolated private static func read(_ pipe: FileHandle, capture: Bool,
                                         log: (@MainActor @Sendable (String) -> Void)?) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var collected = Data()
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(pipe.fileDescriptor, bytes.baseAddress, bytes.count)
                }
                if count == 0 { break }
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                let data = Data(buffer.prefix(count))
                collected.append(data)
                if !capture, collected.count > 8_192 { collected.removeFirst(collected.count - 8_192) }
                if let log {
                    pending.append(data)
                    if let newline = pending.lastIndex(of: 10) {
                        await log(String(decoding: pending[...newline], as: UTF8.self))
                        pending.removeSubrange(...newline)
                    } else if pending.count > 8_192, let chunk = String(data: pending, encoding: .utf8) {
                        await log(chunk)
                        pending.removeAll()
                    }
                }
            }
            if let log, !pending.isEmpty { await log(String(decoding: pending, as: UTF8.self)) }
            return String(decoding: collected, as: UTF8.self)
        }.value
    }
}

@MainActor
final class HomebrewModel: ObservableObject {
    @Published private(set) var executable: URL?
    @Published private(set) var installed: [BrewPackage] = []
    @Published private(set) var taps: [String] = []
    @Published private(set) var results: [BrewPackage] = []
    @Published private(set) var log: [BrewLogEntry] = []
    @Published private(set) var configuredPath: String
    @Published private(set) var error: String?
    @Published private(set) var outcome: BrewOutcome?
    @Published private(set) var activity: String?
    @Published private(set) var isCancelling = false
    private(set) var changingSystem = false
    private var stopping = false
    private let runner = BrewProcess()
    private let defaults: UserDefaults
    private static let executableKey = "homebrew.executablePath"
    private var logBytes = 0
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuredPath = defaults.string(forKey: Self.executableKey) ?? ""
    }

    var busy: Bool { task != nil }

    func startIfNeeded() {
        if executable == nil, error == nil { refresh() }
    }

    func refresh() {
        start(L10n.text("读取 Homebrew 状态")) {
            if self.configuredPath.isEmpty {
                self.setExecutable(Self.locateBrew())
            } else {
                do {
                    self.setExecutable(try Self.executableURL(self.configuredPath))
                } catch {
                    self.setExecutable(nil)
                    throw error
                }
            }
            try await self.loadState()
        }
    }

    func applyExecutablePath(_ input: String) {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        start(L10n.text("应用 brew 路径")) {
            let executable: URL?
            if path.isEmpty {
                executable = Self.locateBrew()
            } else {
                let candidate = try Self.executableURL(path)
                self.appendLog("$ " + candidate.path + " --version\n", as: .command)
                let result = try await self.runner.run(candidate, arguments: ["--version"], capture: true) {
                    self.appendProcessOutput($0, stderr: $1)
                }
                try Task.checkCancellation()
                try self.requireSuccess(result)
                guard result.output.hasPrefix("Homebrew ") else { throw BrewError.notHomebrew }
                self.appendLog(result.output)
                executable = candidate
            }
            self.configuredPath = path.isEmpty ? "" : executable?.path ?? ""
            if self.configuredPath.isEmpty {
                self.defaults.removeObject(forKey: Self.executableKey)
            } else {
                self.defaults.set(self.configuredPath, forKey: Self.executableKey)
            }
            self.setExecutable(executable)
            try await self.loadState()
        }
    }

    private func setExecutable(_ url: URL?) {
        guard executable != url else { return }
        executable = url
        installed = []
        results = []
        taps = []
    }

    func search(_ query: String, kinds: [BrewPackageKind]) {
        guard BrewPackage.validName(query) else { return }
        start(L10n.text("搜索 %@", query)) {
            self.results = []
            var matches: [BrewPackage] = []
            for kind in kinds {
                let result = try await self.command(["search", kind.option, "--", query], capture: true)
                if result.status != 0 {
                    if result.status == 1, result.errors.contains("No formulae or casks found") { continue }
                    try self.requireSuccess(result)
                }
                matches += result.output.split(whereSeparator: \.isNewline).map(String.init)
                    .filter(BrewPackage.validName).map { BrewPackage(kind: kind, name: $0) }
            }
            var seen = Set<String>()
            self.results = matches.filter { seen.insert($0.id).inserted }.sorted(by: Self.packageOrder)
            self.appendLog(L10n.text("找到 %@ 个包。\n", self.results.count))
        }
    }

    func showDetails(_ package: BrewPackage) {
        guard BrewPackage.validName(package.name) else { return }
        start(L10n.text("读取 %@ 的详情", package.name)) {
            let result = try await self.checked(["info", "--json=v2", package.kind.option, "--", package.name], capture: true)
            let items = try JSONDecoder().decode(BrewInventory.self, from: Data(result.output.utf8)).packages
            if let details = items.first, let index = self.results.firstIndex(where: { $0.id == package.id }) {
                self.results[index].description = details.description
                self.results[index].homepage = details.homepage
                self.results[index].availableVersion = details.availableVersion
            }
        }
    }

    func change(_ action: BrewPackageAction, package: BrewPackage) {
        guard BrewPackage.validName(package.name) else { return }
        start("\(action.title) \(package.name)", changesSystem: true) {
            try await self.mutate([action.rawValue, package.kind.option, "--", package.name], refresh: self.loadInventory)
        }
    }

    func changeTap(_ name: String, adding: Bool) {
        guard Self.validTap(name) else { return }
        start((adding ? L10n.text("添加 ") : L10n.text("移除 ")) + name, changesSystem: true) {
            try await self.mutate([adding ? "tap" : "untap", "--", name], refresh: self.loadTaps)
        }
    }

    func perform(_ operation: BrewMaintenance) {
        start(operation.title, changesSystem: operation.changesSystem) {
            switch operation {
            case .update:
                try await self.mutate(operation.arguments, refresh: self.loadState)
            case .upgrade, .cleanup:
                try await self.mutate(operation.arguments, refresh: self.loadInventory)
            case .doctor:
                let result = try await self.command(operation.arguments, capture: false)
                let warnings = (result.output + "\n" + result.errors).contains("Warning:")
                if result.status == 1, warnings {
                    self.outcome = .warning
                    self.appendLog(L10n.text("诊断发现需要关注的项目。\n"), as: .warning)
                } else {
                    try self.requireSuccess(result)
                }
            case .config, .previewCleanup:
                _ = try await self.checked(operation.arguments)
            }
        }
    }

    private func mutate(_ arguments: [String], refresh: () async throws -> Void) async throws {
        do {
            _ = try await checked(arguments)
        } catch {
            if !Task.isCancelled { try? await refresh() }
            throw error
        }
        try await refresh()
    }

    func clearLog() {
        log = []
        logBytes = 0
    }

    func cancel() {
        guard busy, !isCancelling else { return }
        isCancelling = true
        task?.cancel()
        runner.cancel()
    }

    func cancelAndWait() async {
        stopping = true
        cancel()
        await task?.value
    }

    private func start(_ label: String, changesSystem: Bool = false, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        activity = label
        changingSystem = changesSystem
        error = nil
        outcome = nil
        task = Task {
            defer {
                task = nil
                activity = nil
                isCancelling = false
                changingSystem = false
                if changesSystem, Task.isCancelled, !stopping { refresh() }
            }
            do {
                try await operation()
                try Task.checkCancellation()
                if outcome == nil {
                    outcome = .success
                    appendLog(L10n.text("%@完成。\n", label), as: .success)
                }
            } catch is CancellationError {
                outcome = .cancelled
                appendLog(L10n.text("操作已取消。\n"), as: .warning)
            } catch {
                outcome = .failure
                let detail = error.localizedDescription
                self.error = String(detail.prefix(350))
                appendLog(detail + "\n", as: .error)
            }
        }
    }

    private func loadState() async throws {
        try await loadInventory()
        try await loadTaps()
    }

    private func loadInventory() async throws {
        let result = try await checked(["info", "--json=v2", "--installed"], capture: true)
        let inventory = try JSONDecoder().decode(BrewInventory.self, from: Data(result.output.utf8))
        installed = inventory.packages.sorted(by: Self.packageOrder)
        appendLog(L10n.text("已读取 %@ 个包。\n", installed.count))
    }

    private func loadTaps() async throws {
        let result = try await checked(["tap"], capture: true)
        taps = result.output.split(whereSeparator: \.isNewline).map(String.init)
            .filter(Self.validTap).sorted()
        appendLog(L10n.text("已读取 %@ 个软件源。\n", taps.count))
    }

    private func checked(_ arguments: [String], capture: Bool = false) async throws -> BrewCommandResult {
        let result = try await command(arguments, capture: capture)
        try requireSuccess(result)
        return result
    }

    private func command(_ arguments: [String], capture: Bool) async throws -> BrewCommandResult {
        guard let executable else { throw BrewError.missingExecutable }
        appendLog("$ brew " + arguments.joined(separator: " ") + "\n", as: .command)
        let result = try await runner.run(executable, arguments: arguments, capture: capture) { [weak self] in
            self?.appendProcessOutput($0, stderr: $1)
        }
        try Task.checkCancellation()
        return result
    }

    private func requireSuccess(_ result: BrewCommandResult) throws {
        guard result.status == 0 else {
            let errors = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrewError.failed(result.status, errors.isEmpty ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : errors)
        }
    }

    private func appendProcessOutput(_ text: String, stderr: Bool) {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var kind: BrewLogEntry.Kind = stderr ? .warning : .output
        var block = ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let next: BrewLogEntry.Kind
            if line.hasPrefix("Error:") { next = .error }
            else if line.hasPrefix("Warning:") { next = .warning }
            else { next = stderr ? kind : .output }
            if next != kind {
                appendLog(block, as: kind)
                block = ""
                kind = next
            }
            block += line
            if index < lines.count - 1 { block += "\n" }
        }
        appendLog(block, as: kind)
    }

    private func appendLog(_ text: String, as kind: BrewLogEntry.Kind = .output) {
        guard !text.isEmpty else { return }
        let message = String(text.suffix(16_000))
        logBytes += message.utf8.count
        log.append(BrewLogEntry(kind: kind, message: message))
        while log.count > 1, logBytes > 48_000 || log.count > 400 {
            logBytes -= log.removeFirst().message.utf8.count
        }
    }

    private static func executableURL(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw BrewError.invalidPath }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false,
              FileManager.default.isExecutableFile(atPath: url.path) else { throw BrewError.invalidPath }
        return url
    }

    nonisolated static func validTap(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_.-]*\/[a-zA-Z0-9][a-zA-Z0-9_.-]*/) != nil
    }

    private nonisolated static func packageOrder(_ first: BrewPackage, _ second: BrewPackage) -> Bool {
        first.name.localizedStandardCompare(second.name) == .orderedAscending
    }

    private static func locateBrew() -> URL? {
        #if arch(arm64)
        let defaults = ["/opt/homebrew/bin", "/usr/local/bin"]
        #else
        let defaults = ["/usr/local/bin", "/opt/homebrew/bin"]
        #endif
        let directories = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (defaults + directories.filter { $0.hasPrefix("/") }).lazy
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("brew") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
