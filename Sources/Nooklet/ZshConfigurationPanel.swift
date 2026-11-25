import AppKit
import NookletCore
import SwiftUI

@MainActor
final class ZshConfigurationModel: ObservableObject {
    private struct Draft {
        let original: ZshConfigFile
        var text: String
    }

    @Published private(set) var snapshot = ZshConfigSnapshot()
    @Published private var drafts: [String: Draft] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var saving = false
    @Published private(set) var notice = ""
    @Published private(set) var failed = false
    private var loaded = false

    var files: [ZshConfigFile] {
        let known = Set(snapshot.files.map(\.id))
        return snapshot.files + drafts.values.map(\.original).filter { !known.contains($0.id) }
            .sorted { $0.url.path < $1.url.path }
    }
    var hasDrafts: Bool { !drafts.isEmpty }

    func startIfNeeded() {
        if !loaded { refresh() }
    }

    func refresh() {
        guard !scanning, !saving else { return }
        scanning = true
        notice = ""
        failed = false
        Task {
            snapshot = await Task.detached { ZshConfigurationFiles.scan() }.value
            scanning = false
            loaded = true
        }
    }

    func text(for file: ZshConfigFile) -> String { drafts[file.id]?.text ?? file.text ?? "" }
    func isDirty(_ file: ZshConfigFile) -> Bool { drafts[file.id] != nil }

    func edit(_ text: String, file: ZshConfigFile) {
        guard !saving, file.editable else { return }
        let original = drafts[file.id]?.original ?? file
        drafts[file.id] = text == (original.text ?? "") ? nil : Draft(original: original, text: text)
        notice = ""
        failed = false
    }

    func reload(_ file: ZshConfigFile) {
        drafts[file.id] = nil
        refresh()
    }

    func save(_ file: ZshConfigFile) {
        guard !saving, !scanning, file.editable else { return }
        let draft = drafts[file.id] ?? Draft(original: file, text: file.text ?? "")
        saving = true
        notice = ""
        failed = false
        Task {
            do {
                snapshot = try await Task.detached {
                    try Self.checkSyntax(draft.text)
                    try ZshConfigurationFiles.save(draft.text, to: draft.original)
                    return ZshConfigurationFiles.scan()
                }.value
                drafts[file.id] = nil
                notice = L10n.text("已保存 %@", file.url.lastPathComponent)
            } catch {
                notice = error.localizedDescription
                failed = true
            }
            saving = false
        }
    }

    private nonisolated static func checkSyntax(_ text: String) throws {
        guard text.utf8.count <= ZshConfigurationFiles.fileSizeLimit, !text.utf8.contains(0) else {
            throw ZshConfigError.unreadable
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("config.zsh")
        let errors = directory.appendingPathComponent("stderr")
        try Data(text.utf8).write(to: script)
        try Data().write(to: errors)
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fn", "--", script.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let report = (try? String(contentsOf: errors, encoding: .utf8))?
                .replacingOccurrences(of: script.path, with: "Zsh")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ZshConfigError.invalidSyntax(report.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Zsh 语法检查未通过。"))
        }
    }
}

@MainActor
final class ZshConfigurationPanel: ToolPanel {
    private let model: ZshConfigurationModel

    init(heading: String, detail: String, model: ZshConfigurationModel) {
        self.model = model
        super.init(heading: heading, detail: detail)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        let hosting = NSHostingView(rootView: ZshConfigurationView(model: model))
        hosting.sizingOptions = []
        return hosting
    }

    override func setVisible(_ visible: Bool) {
        if visible { model.startIfNeeded() }
    }
}

@MainActor
private struct ZshConfigurationView: View {
    @ObservedObject var model: ZshConfigurationModel
    @State private var selected: String?
    @State private var query = ""
    @State private var showReferences = false
    @State private var confirmReload = false

    private var filtered: [ZshConfigFile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.files }
        return model.files.filter { file in
            file.url.path.localizedStandardContains(needle)
                || model.text(for: file).localizedStandardContains(needle)
                || file.references.contains { $0.expression.localizedStandardContains(needle) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WorkspaceField(title: L10n.text("搜索文件名、路径或配置内容"), symbol: "magnifyingglass", text: $query, tint: .accent)
                Spacer(minLength: 4)
                if model.scanning || model.saving { ProgressView().controlSize(.small) }
                Button(L10n.text("重新扫描"), systemImage: "arrow.clockwise", action: model.refresh)
                    .buttonStyle(WorkspaceActionStyle(tint: .neutral))
                    .disabled(model.scanning || model.saving)
            }
            if model.snapshot.limited {
                Label(L10n.text("已达到扫描上限，部分引用未展开。"), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                browser
                if let file = model.files.first(where: { $0.id == selected }) {
                    editor(file)
                } else {
                    VStack(spacing: 8) {
                        WorkspaceGlyph(symbol: "terminal", tint: .accent, size: 44)
                        Text(L10n.text("选择配置文件")).font(.callout).foregroundStyle(.secondary)
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolboxCard()
                }
            }
            if !model.notice.isEmpty {
                Label(model.notice, systemImage: model.failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.callout).foregroundStyle((model.failed ? WorkspaceTint.danger : .success).foreground)
                    .lineLimit(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background((model.failed ? WorkspaceTint.danger : .success).foreground.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .onAppear(perform: selectDefault)
        .onChange(of: model.files.map(\.id)) { _, _ in selectDefault() }
    }

    private var browser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                fileGroup(L10n.text("启动文件"), symbol: "power", files: filtered.filter(\.startup))
                fileGroup(L10n.text("引入的配置"), symbol: "arrow.turn.down.right", files: filtered.filter { !$0.startup })
                if filtered.isEmpty {
                    Text(model.scanning ? L10n.text("正在扫描…") : L10n.text("没有匹配的文件"))
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(9)
                }
            }.padding(5)
        }
        .frame(minWidth: 145, idealWidth: 188, maxWidth: 218, maxHeight: .infinity)
        .toolboxCard()
    }

    private func fileGroup(_ title: String, symbol: String, files: [ZshConfigFile]) -> some View {
        Group {
            if !files.isEmpty {
                Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(WorkspaceTint.neutral.foreground)
                    .padding(.leading, 7).padding(.top, 7).padding(.bottom, 3)
                ForEach(files) { file in
                    Button {
                        selected = file.id
                    } label: {
                        HStack(spacing: 7) {
                            WorkspaceGlyph(symbol: file.editable ? "doc.text" : "lock.doc", tint: file.id == selected ? .accent : .neutral, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.url.lastPathComponent).font(.callout.weight(.medium))
                                Text(file.url.deletingLastPathComponent().path)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if model.isDirty(file) {
                                Image(systemName: "circle.fill").font(.system(size: 6))
                                    .foregroundStyle(Color(nsColor: ToolboxAppearance.amber))
                                    .accessibilityLabel(L10n.text("有未保存的修改"))
                            }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 6)
                        .background(file.id == selected ? Color(nsColor: ToolboxAppearance.selection) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .leading) {
                            if file.id == selected {
                                Capsule().fill(WorkspaceTint.accent.foreground).frame(width: 2, height: 21).allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file.url.path)
                    .accessibilityAddTraits(file.id == selected ? [.isSelected] : [])
                }
            }
        }
    }

    private func editor(_ file: ZshConfigFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                WorkspaceGlyph(symbol: "doc.text", tint: .accent, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.url.lastPathComponent).font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(file.url.path).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(file.target.path)
                }
                Spacer(minLength: 0)
                if file.editable {
                    Button(L10n.text("重新载入"), systemImage: "arrow.counterclockwise") {
                        if model.isDirty(file) { confirmReload = true } else { model.reload(file) }
                    }
                    .buttonStyle(WorkspaceActionStyle(tint: .neutral))
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(model.saving || model.scanning)
                    Button(file.data == nil ? L10n.text("创建") : L10n.text("保存"), systemImage: "checkmark") { model.save(file) }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(WorkspaceActionStyle(tint: .accent, prominent: true))
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(model.saving || model.scanning || (file.data != nil && !model.isDirty(file)))
                } else {
                    Label(L10n.text("只读"), systemImage: "lock").font(.caption)
                        .foregroundStyle(WorkspaceTint.warning.foreground)
                }
            }
            .padding(10)
            .background(alignment: .leading) {
                LinearGradient(colors: [WorkspaceTint.accent.foreground.opacity(0.07), .clear],
                               startPoint: .leading, endPoint: .trailing)
            }

            if file.text == nil && !file.editable {
                ContentUnavailableView(L10n.text("无法预览此文件"), systemImage: "doc.questionmark",
                                       description: Text(L10n.text("仅支持 512 KB 以内的 UTF-8 文本。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ZshTextEditor(text: Binding(get: { model.text(for: file) }, set: { model.edit($0, file: file) }),
                                  editable: file.editable && !model.saving)
                        .id(file.id)
                        .accessibilityLabel(L10n.text("编辑 %@", file.url.lastPathComponent))
                        .frame(minHeight: 72, maxHeight: .infinity)
                    editorStatus(file)
                }
                .background(WorkspaceTerminal.background)
            }
            references(file)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .toolboxCard()
        .alert(L10n.text("舍弃「%@」的未保存修改？", file.url.lastPathComponent), isPresented: $confirmReload) {
            Button(L10n.text("舍弃并重新载入"), role: .destructive) { model.reload(file) }
            Button(L10n.text("取消"), role: .cancel) {}
        }
    }

    private func editorStatus(_ file: ZshConfigFile) -> some View {
        let changed = model.isDirty(file)
        return HStack(spacing: 6) {
            Label("Zsh", systemImage: "chevron.left.forwardslash.chevron.right").foregroundStyle(WorkspaceTerminal.accent)
            Text("UTF-8").foregroundStyle(WorkspaceTerminal.subdued)
            Spacer()
            if changed {
                Label(L10n.text("未保存"), systemImage: "circle.fill").foregroundStyle(WorkspaceTerminal.warning)
            } else if file.data == nil {
                Label(L10n.text("待创建"), systemImage: "doc.badge.plus").foregroundStyle(WorkspaceTerminal.warning)
            } else if !file.editable {
                Label(L10n.text("只读"), systemImage: "lock").foregroundStyle(WorkspaceTerminal.subdued)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(WorkspaceTerminal.header)
    }

    @ViewBuilder
    private func references(_ file: ZshConfigFile) -> some View {
        if !file.references.isEmpty {
            DisclosureGroup(isExpanded: $showReferences) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(file.references) { ref in
                            if let target = ref.target {
                                Button {
                                    query = ""
                                    selected = target
                                } label: {
                                    Label(L10n.text("第 %@ 行 · %@", ref.line, ref.expression), systemImage: "arrow.turn.down.right")
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .buttonStyle(.link)
                                .foregroundStyle(WorkspaceTint.accent.foreground)
                                .help(target)
                            } else {
                                Text(L10n.text("第 %@ 行 · %@（未解析）", ref.line, ref.expression))
                                    .foregroundStyle(WorkspaceTint.warning.foreground).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(90, CGFloat(file.references.count * 20 + 4)))
            } label: {
                Label(L10n.text("引用 %@ 项", file.references.count), systemImage: "link")
                    .font(.caption.weight(.semibold)).foregroundStyle(WorkspaceTint.neutral.foreground)
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .tint(WorkspaceTint.accent.foreground)
        }
    }

    private func selectDefault() {
        if let selected, model.files.contains(where: { $0.id == selected }) { return }
        selected = model.files.first { $0.url.lastPathComponent == ".zshrc" }?.id ?? model.files.first?.id
    }
}
