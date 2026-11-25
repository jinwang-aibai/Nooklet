import Foundation

package struct ZshConfigFile: Identifiable, Sendable {
    package struct Reference: Identifiable, Sendable {
        package let line: Int
        package let expression: String
        package let target: String?
        package var id: String { "\(line):\(expression)" }
    }

    package var id: String { target.path }
    package let url: URL
    package let target: URL
    package let startup: Bool
    package let data: Data?
    package let text: String?
    package let editable: Bool
    package var references: [Reference] = []
}

package struct ZshConfigSnapshot: Sendable {
    package var files: [ZshConfigFile] = []
    package var limited = false

    package init() {}
}

package enum ZshConfigError: LocalizedError {
    case changedOnDisk, unreadable, invalidSyntax(String)

    package var errorDescription: String? {
        switch self {
        case .changedOnDisk: NookletLocalization.text("文件已在其他地方更改。请重新扫描并载入磁盘版本后再保存。")
        case .unreadable: NookletLocalization.text("此文件无法读取、不是 UTF-8 文本，或超过编辑大小限制。")
        case .invalidSyntax(let detail): detail
        }
    }
}

package enum ZshConfigurationFiles {
    package static let fileSizeLimit = 512 * 1024

    package static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemDirectory: URL = URL(fileURLWithPath: "/etc", isDirectory: true)
    ) -> ZshConfigSnapshot {
        var scanner = Scanner(home: home, environment: environment)
        for name in ["zshenv", "zprofile", "zshrc", "zlogin"] {
            scanner.visit(systemDirectory.appendingPathComponent(name), startup: true)
            scanner.visitUserFile(name)
        }
        scanner.visitUserFile("zlogout")
        scanner.visit(systemDirectory.appendingPathComponent("zlogout"), startup: true)
        return scanner.snapshot
    }

    package static func save(_ text: String, to file: ZshConfigFile) throws {
        guard file.editable else { throw ZshConfigError.unreadable }
        let manager = FileManager.default
        let target = file.url.resolvingSymlinksInPath()
        guard target == file.target else { throw ZshConfigError.changedOnDisk }
        let current = try? read(target)
        guard current == file.data, current != nil || !manager.fileExists(atPath: target.path) else {
            throw ZshConfigError.changedOnDisk
        }
        var data = Data(text.utf8)
        if file.data?.starts(with: [0xEF, 0xBB, 0xBF]) == true {
            data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: data.startIndex)
        }
        guard data.count <= fileSizeLimit else { throw ZshConfigError.unreadable }
        if current == nil {
            try data.write(to: target, options: .withoutOverwriting)
        } else {
            try data.write(to: target, options: .atomic)
        }
    }

    private static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= fileSizeLimit else {
            throw ZshConfigError.unreadable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: fileSizeLimit + 1) ?? Data()
        guard data.count <= fileSizeLimit, !data.contains(0) else { throw ZshConfigError.unreadable }
        return data
    }

    private struct Scanner {
        let home: URL
        var variables: [String: String]
        var snapshot = ZshConfigSnapshot()
        private var indices: [String: Int] = [:]
        private var totalBytes = 0

        init(home: URL, environment: [String: String]) {
            self.home = home
            variables = environment
            variables["HOME"] = home.path
        }

        mutating func visitUserFile(_ name: String) {
            let directory = variables["ZDOTDIR"].flatMap { value in
                value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil
            } ?? home
            visit(directory.appendingPathComponent("." + name), startup: true, offerCreation: name == "zshrc")
        }

        @discardableResult
        mutating func visit(_ url: URL, startup: Bool = false, offerCreation: Bool = false, depth: Int = 0) -> String? {
            let manager = FileManager.default
            let target = url.resolvingSymlinksInPath()
            if let index = indices[target.path] {
                if startup, !snapshot.files[index].startup {
                    let file = snapshot.files[index]
                    snapshot.files[index] = ZshConfigFile(url: file.url, target: file.target, startup: true, data: file.data,
                                                         text: file.text, editable: file.editable, references: file.references)
                }
                return target.path
            }
            let exists = manager.fileExists(atPath: target.path)
            guard exists || (offerCreation && manager.isWritableFile(atPath: target.deletingLastPathComponent().path)) else { return nil }
            guard snapshot.files.count < 256, totalBytes < 8 * 1024 * 1024, depth <= 24 else {
                snapshot.limited = true
                return nil
            }

            let data = exists ? try? read(target) : nil
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            totalBytes += data?.count ?? 0
            let editable = (text != nil || !exists) && manager.isWritableFile(atPath: target.deletingLastPathComponent().path)
                && (!exists || manager.isWritableFile(atPath: target.path))
            let index = snapshot.files.endIndex
            indices[target.path] = index
            snapshot.files.append(ZshConfigFile(url: url, target: target, startup: startup, data: data,
                                              text: text, editable: editable))
            guard let text else { return target.path }

            var references: [ZshConfigFile.Reference] = []
            var seen = Set<String>()
            for statement in ZshSourceStatements.parse(text) {
                switch statement {
                case .assignment(let key, let expression):
                    variables[key] = expand(expression, in: url)
                case .include(let expression, let line, let dot):
                    let destination = expand(expression, in: url).flatMap { locate($0, from: url, dot: dot) }
                    let resolved = destination.flatMap { visit($0, depth: depth + 1) }
                    let reference = ZshConfigFile.Reference(line: line, expression: expression, target: resolved)
                    if seen.insert(reference.id).inserted { references.append(reference) }
                }
            }
            snapshot.files[index].references = references
            return target.path
        }

        private func locate(_ path: String, from source: URL, dot: Bool) -> URL? {
            guard !path.isEmpty else { return nil }
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            // A login shell typically starts in the home directory. Also check beside the source.
            let local = [home, source.deletingLastPathComponent()]
            let pathDirectories = (variables["PATH"] ?? "").components(separatedBy: ":").compactMap {
                $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
            }
            let directories = path.contains("/") ? local : (dot ? pathDirectories + local : local + pathDirectories)
            return directories.map { $0.appendingPathComponent(path).standardizedFileURL }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }

        private func expand(_ expression: String, in source: URL, nesting: Int = 0) -> String? {
            guard nesting < 4 else { return nil }
            var output = ""
            var quote: Character?
            var cursor = expression.startIndex
            while cursor < expression.endIndex {
                let character = expression[cursor]
                let atStart = cursor == expression.startIndex
                expression.formIndex(after: &cursor)
                if character == quote {
                    quote = nil
                } else if quote == "'" {
                    output.append(character)
                } else if character == "'" || character == "\"" {
                    if quote == nil { quote = character } else { output.append(character) }
                } else if character == "\\" {
                    guard cursor < expression.endIndex else { return nil }
                    let escaped = expression[cursor]
                    if quote == "\"", !"$`\"\\\n".contains(escaped) { output.append("\\") }
                    if escaped != "\n" { output.append(escaped) }
                    expression.formIndex(after: &cursor)
                } else if character == "$" {
                    let remainder = expression[cursor...]
                    if let parameter = remainder.prefixMatch(of: /\{([^{}]+)\}|([A-Za-z_][A-Za-z0-9_]*)/) {
                        cursor = parameter.range.upperBound
                        let contents = String(parameter.1 ?? parameter.2 ?? "")
                        let value: String?
                        switch contents {
                        case "0:A:h":
                            value = source.resolvingSymlinksInPath().deletingLastPathComponent().path
                        case "0:a:h", "(%):-%N:h", "(%):-%x:h":
                            value = source.standardizedFileURL.deletingLastPathComponent().path
                        case "0", "(%):-%N", "(%):-%x":
                            value = source.path
                        default:
                            let pieces = contents.components(separatedBy: ":-")
                            value = variables[pieces[0]].flatMap { $0.isEmpty && pieces.count == 2 ? nil : $0 }
                                ?? (pieces.count == 2 ? expand(pieces[1], in: source, nesting: nesting + 1) : nil)
                        }
                        guard let value else { return nil }
                        output += value
                    } else {
                        return nil
                    }
                } else if character == "~", quote == nil, atStart {
                    guard cursor == expression.endIndex || expression[cursor] == "/" else { return nil }
                    output += home.path
                } else {
                    guard quote != nil || !"`*?[]{}()<>|&;".contains(character) else { return nil }
                    output.append(character)
                }
            }
            return quote == nil ? output : nil
        }
    }
}

private enum ZshSourceStatements {
    enum Statement {
        case assignment(String, String)
        case include(String, Int, dot: Bool)
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: #"""
    (?x)
    [\t ]+ | \x23[^\r\n]* | \r?\n | <<-? (?!<) | <<< | \|\| | && | [;|&()]
    | (?: \\ [\s\S] | '[^']*' | "(?:\\[\s\S]|[^"\\])*" | \x60(?:\\[\s\S]|[^\x60\\])*\x60
        | \$\{[^{}]*\} | (?:\$|[<>])\((?:\\[\s\S]|[^()]|\([^()]*\))*\)
        | [^\s\x23;|&()<>'"\\\x60] | (?<=\S)\x23 )+
    | .
    """#)

    static func parse(_ source: String) -> [Statement] {
        let text = source as NSString
        var result: [Statement] = []
        var command: [(String, Int)] = []
        var cursor = 0
        var line = 1
        var heredocs: [(String, Bool)] = []
        var heredocOperator: String?

        func finish() {
            defer { command.removeAll(keepingCapacity: true) }
            var tokens = ArraySlice(command)
            while let first = tokens.first?.0, ["if", "then", "elif", "else", "do", "{", "!", "builtin", "command"].contains(first) {
                tokens = tokens.dropFirst()
            }
            let declarations = ["export", "typeset", "local", "readonly"]
            let declaration = tokens.first.map { declarations.contains($0.0) } == true
            if declaration { tokens = tokens.dropFirst() }
            while let first = tokens.first, let assignment = first.0.prefixMatch(of: /([A-Za-z_][A-Za-z0-9_]*)=/) {
                result.append(.assignment(String(assignment.1), String(first.0[assignment.range.upperBound...])))
                tokens = tokens.dropFirst()
            }
            guard !declaration, let first = tokens.first, [".", "source"].contains(first.0) else { return }
            let arguments = tokens.dropFirst()
            if let expression = arguments.first(where: { $0.0 != "--" }) {
                result.append(.include(expression.0, first.1, dot: first.0 == "."))
            }
        }

        while cursor < text.length {
            let range = NSRange(location: cursor, length: text.length - cursor)
            guard let match = tokenPattern.firstMatch(in: source, options: .anchored, range: range) else {
                cursor += 1
                continue
            }
            let token = text.substring(with: match.range)
            cursor = NSMaxRange(match.range)
            if token == "\n" || token == "\r\n" {
                finish()
                line += 1
                for (delimiter, stripTabs) in heredocs {
                    while cursor < text.length {
                        let range = text.lineRange(for: NSRange(location: cursor, length: 0))
                        var body = text.substring(with: range).trimmingCharacters(in: .newlines)
                        if stripTabs { body = String(body.drop(while: { $0 == "\t" })) }
                        cursor = NSMaxRange(range)
                        line += 1
                        if body == delimiter { break }
                    }
                }
                heredocs.removeAll()
                heredocOperator = nil
            } else if token == "\\\n" || token == "\\\r\n" {
                line += 1
            } else if token.hasPrefix("#") || token.allSatisfy(\.isWhitespace) {
                continue
            } else if token == "<<" || token == "<<-" {
                heredocOperator = token
            } else if let op = heredocOperator {
                let delimiter = token.filter { !"'\"\\".contains($0) }
                heredocs.append((delimiter, op == "<<-"))
                heredocOperator = nil
            } else if [";", "|", "||", "&", "&&", "(", ")"].contains(token) {
                finish()
            } else {
                command.append((token, line))
                line += token.filter(\.isNewline).count
            }
        }
        finish()
        return result
    }
}
