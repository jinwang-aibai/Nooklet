import AppKit
import NookletCore
import SwiftUI

@MainActor
final class GeneralSettingsPanel: ToolPanel {
    private let model: ToolboxModel

    init(model: ToolboxModel) {
        self.model = model
        super.init(heading: L10n.text("基础信息"), detail: "")
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        let hosting = NSHostingView(rootView: GeneralSettingsView(model: model))
        hosting.sizingOptions = []
        return hosting
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: ToolboxModel
    private let secondary = Color(nsColor: ToolboxAppearance.secondary)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("版本") {
                    row {
                        Text(L10n.text("当前版本"))
                        Spacer()
                        Text(AppVersion.current.version ?? L10n.text("未知"))
                            .monospacedDigit()
                            .foregroundStyle(secondary)
                            .textSelection(.enabled)
                    }
                    if let build = AppVersion.current.build {
                        Divider()
                        row {
                            Text(L10n.text("构建号"))
                            Spacer()
                            Text(build)
                                .monospacedDigit()
                                .foregroundStyle(secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Divider()
                    SoftwareUpdateRow(model: model.softwareUpdate)
                        .padding(.vertical, 10)
                }

                section("偏好设置") {
                    VStack(alignment: .leading, spacing: 4) {
                        picker("语言", selection: binding(\.language)) {
                            Text(L10n.text("跟随系统")).tag(AppLanguage.system)
                            Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                            Text(verbatim: "English").tag(AppLanguage.english)
                        }
                        if model.general.language.resolved() != L10n.language {
                            Text(L10n.text("重启 Nooklet 后应用所选语言。"))
                                .font(.caption)
                                .foregroundStyle(secondary)
                        }
                    }
                    .padding(.vertical, 10)
                    Divider()
                    picker("颜色", selection: binding(\.theme)) {
                        ForEach(GeneralPreferences.Theme.allCases, id: \.self) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .padding(.vertical, 10)
                    if model.general.theme == .custom {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L10n.text("强调色")).accessibilityHidden(true)
                                Spacer()
                                ColorPicker(L10n.text("强调色"), selection: customColor, supportsOpacity: false)
                                    .labelsHidden()
                                    .fixedSize()
                            }
                            Text(L10n.text("窗口底色随系统亮暗模式切换。"))
                                .font(.caption)
                                .foregroundStyle(secondary)
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
        }
        .foregroundStyle(Color(nsColor: ToolboxAppearance.ink))
        .tint(model.general.accent.map(Color.init(nsColor:)))
    }

    private func picker<Value: Hashable, Content: View>(
        _ title: String, selection: Binding<Value>, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(L10n.text(title))
                .accessibilityHidden(true)
            Spacer()
            Picker(L10n.text(title), selection: selection, content: content)
                .labelsHidden()
                .fixedSize()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .toolboxCard()
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16, content: content)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
    }

    private func binding<Value>(_ path: WritableKeyPath<GeneralPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.general[keyPath: path] }, set: { value in
            model.updateGeneral { $0[keyPath: path] = value }
        })
    }

    private var customColor: Binding<Color> {
        Binding(get: { Color(nsColor: ToolboxAppearance.rgb(model.general.customColor)) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let red = UInt32((min(max(rgb.redComponent, 0), 1) * 255).rounded())
            let green = UInt32((min(max(rgb.greenComponent, 0), 1) * 255).rounded())
            let blue = UInt32((min(max(rgb.blueComponent, 0), 1) * 255).rounded())
            model.updateGeneral { $0.customColor = red << 16 | green << 8 | blue }
        })
    }
}

private struct SoftwareUpdateRow: View {
    @ObservedObject var model: SoftwareUpdateModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("版本更新"))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .result(.available(_, releasePage)) = model.state {
                    Link(L10n.text("查看发布与下载"), destination: releasePage)
                        .font(.callout)
                }
            }
            Spacer(minLength: 0)
            if model.state == .checking {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
            Button(L10n.text("检查更新"), action: model.check)
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(model.state == .checking)
        }
    }

    private var status: String {
        switch model.state {
        case .idle: L10n.text("从 GitHub 检查最新稳定版本。")
        case .checking: L10n.text("正在检查更新…")
        case .result(.noRelease): L10n.text("GitHub 暂无已发布的稳定版本。")
        case .result(.upToDate): L10n.text("已是最新稳定版本。")
        case let .result(.available(version, _)): L10n.text("Nooklet %@ 已发布。", version)
        case let .failed(message): message
        }
    }
}

private extension GeneralPreferences.Theme {
    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .black: L10n.text("黑色")
        case .white: L10n.text("白色")
        case .custom: L10n.text("自定义颜色")
        }
    }
}
