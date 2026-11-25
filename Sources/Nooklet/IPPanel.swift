import AppKit
import NookletCore
import SwiftUI
import WebKit

@MainActor
final class IPPanel: ToolPanel {
    private let diagnostics: IPDiagnosticsModel

    init(heading: String, paths: AppPaths) {
        diagnostics = IPDiagnosticsModel(paths: paths)
        super.init(heading: heading, detail: L10n.text("查看公网出口、局域网地址、归属地与网络测速摘要。"))
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        let hosting = NSHostingView(rootView: IPDiagnosticsView(model: diagnostics))
        hosting.sizingOptions = []
        return hosting
    }

    override func endUse() { diagnostics.cancelAll() }
}

@MainActor
private struct IPDiagnosticsView: View {
    @ObservedObject var model: IPDiagnosticsModel
    @State private var targetName = ""
    @State private var targetURL = ""
    private let speedTint = Color(red: 0.02, green: 0.64, blue: 0.69)
    private let columns = Array(repeating: GridItem(.flexible(minimum: 120), spacing: 14), count: 2)

    var body: some View {
        VStack(alignment: .trailing, spacing: 13) {
            HStack {
                Spacer()
                Button {
                    model.toggleHidden()
                } label: {
                    Image(systemName: model.hidden ? "eye.slash" : "eye").frame(width: 15)
                }
                .accessibilityLabel(model.hidden ? L10n.text("显示 IP 地址") : L10n.text("隐藏 IP 地址"))
                .help(model.hidden ? L10n.text("显示 IP 地址") : L10n.text("隐藏 IP 地址"))
                Button(model.state(.ip) == .running ? L10n.text("取消检测") : L10n.text("检测 IP"), systemImage: "arrow.clockwise") {
                    model.run(.ip)
                }.buttonStyle(.borderedProminent)
                Button(model.copied ? L10n.text("已复制") : L10n.text("复制结果"), systemImage: model.copied ? "checkmark" : "doc.on.doc") {
                    model.copyResults()
                }.disabled(model.local.isEmpty && model.exits.isEmpty && model.download.isEmpty
                           && model.upload.isEmpty && model.candidates.isEmpty && model.resolvers.isEmpty && model.connectivity.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    section(L10n.text("网络测速"), icon: "speedometer", check: .speed, action: L10n.text("开始测速")) { speedCard }
                    section(L10n.text("公网 IP"), icon: "globe", showsIPProgress: true) { publicCard }
                    section(L10n.text("本地局域网 IP"), icon: "wifi.router") { localCard }
                    section(L10n.text("网络连通性"), icon: "point.3.connected.trianglepath.dotted", check: .connectivity) { connectivityCard }
                    section(L10n.text("WebRTC 泄露测试"), icon: "globe.badge.chevron.backward", check: .webRTC) { webRTCCard }
                    section(L10n.text("DNS 泄露测试"), icon: "shield.lefthalf.filled", check: .dns) { dnsCard }
                    Label(L10n.text("公网、归属地、测速、连通性和泄露检测会访问相应外部服务。局域网地址仅在本机读取。"), systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 9)
                .padding(.bottom, 3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let probe = model.webRTCProbe {
                ProbeWebView(view: probe.view).frame(width: 2, height: 2)
                    .opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func section<Content: View>(_ title: String, icon: String, check: IPDiagnosticsModel.Check? = nil,
                                        action: String? = nil, showsIPProgress: Bool = false,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let check {
                    let running = model.state(check) == .running
                    if running { ProgressView().controlSize(.small) }
                    Button(running ? L10n.text("取消") : action ?? L10n.text("刷新"), systemImage: running ? "xmark" : "arrow.clockwise") { model.run(check) }
                        .controlSize(.small)
                        .accessibilityLabel(running ? L10n.text("取消%@", title) : action ?? L10n.text("刷新%@", title))
                } else if showsIPProgress, model.state(.ip) == .running {
                    ProgressView().controlSize(.small)
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .toolboxCard()
        }
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                speedDial
                VStack(spacing: 9) {
                    rateRow(L10n.text("下载"), points: model.download)
                    rateRow(L10n.text("上传"), points: model.upload)
                }
            }
            HStack(spacing: 13) {
                Text(L10n.text("空闲延迟  ") + (model.latency.map { "\(speedText($0)) ms" } ?? "—"))
                Text(L10n.text("负载响应性  ") + (model.responsiveness.map { "\(speedText($0)) RPM" } ?? "—"))
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            switch model.state(.speed) {
            case .running: caption(model.speedStage)
            case .failed(let message): caption(L10n.text("有测速样本未完成。%@", message))
            case .done where model.responsiveness == nil: caption(L10n.text("未取得完整的负载响应样本。"))
            default: caption(L10n.text("通过 Cloudflare 测量 HTTP 吞吐量和延迟，会按网速调整流量，单次最多约 23 MB。"))
            }
        }
    }

    private var speedDial: some View {
        let isUploading = !model.upload.isEmpty || model.speedStage == L10n.text("测量上传")
        let value = isUploading ? model.upload.last : model.download.last
        let fraction = value.map { min(1.0, log1p($0) / log1p(1_000)) } ?? 0
        return ZStack {
            Circle().strokeBorder(.primary.opacity(0.03), lineWidth: 1).padding(8)
            Circle().trim(from: 0, to: 0.75).stroke(.primary.opacity(0.09), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(135)).padding(5)
            if fraction > 0 {
                Circle().trim(from: 0, to: 0.75 * fraction)
                    .stroke(speedTint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(135)).padding(5)
            }
            VStack(spacing: 2) {
                Text(value.map(speedText) ?? "—").font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text("Mbps").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(width: 108, height: 108).accessibilityHidden(true)
    }

    private func rateRow(_ name: String, points: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(name).fontWeight(.semibold)
                Text((points.last.map(speedText) ?? "—") + " Mbps")
                    .font(.caption.monospacedDigit()).foregroundStyle(speedTint)
            }
            SpeedTrace(values: points, tint: speedTint)
                .frame(height: 36)
                .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
        }
    }

    private var publicCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.exits.isEmpty {
                caption(model.state(.ip) == .running ? L10n.text("正在查询国内与国际出口…") : L10n.text("点击「检测 IP」查询出口地址和归属地。"))
            } else {
                ForEach(model.exits) { exit in
                    if exit.id != model.exits.first?.id { Divider() }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if let address = exit.address { addressText(address); family(address) }
                            else { Text(L10n.text("未取得地址")).foregroundStyle(.secondary) }
                            badge(L10n.text(exit.route.rawValue), color: exit.route == .domestic ? .green : .orange)
                            Spacer(minLength: 0)
                            Text(exit.source).font(.caption2).foregroundStyle(.secondary)
                        }
                        let details = [exit.location, exit.provider, exit.asn.map { "AS\($0)" } ?? ""].filter { !$0.isEmpty }
                        caption(details.isEmpty ? L10n.text("归属地暂不可用") : details.joined(separator: " · "))
                    }
                }
                caption(L10n.text("各出口由对应服务观察，结果受当前代理与路由影响。"))
            }
        }
    }

    private var localCard: some View {
        let grouped = Dictionary(grouping: model.local, by: \.interface)
        var seen = Set<String>()
        let interfaces = model.local.map(\.interface).filter { seen.insert($0).inserted }
        return VStack(alignment: .leading, spacing: 8) {
            if let error = model.localError {
                caption(L10n.text("读取本机地址失败。%@", error))
            } else if interfaces.isEmpty {
                caption(L10n.text("暂无可用的本机地址。"))
            } else {
                ForEach(interfaces, id: \.self) { name in
                    if name != interfaces.first { Divider() }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.subheadline.weight(.semibold))
                        ForEach(grouped[name] ?? [], id: \.self) { item in
                            HStack(spacing: 7) { addressText(item.address); family(item.address) }
                        }
                    }
                }
            }
        }
    }

    private var connectivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(model.targets) { target in
                    targetRow(target)
                }
            }
            HStack(spacing: 6) {
                TextField(L10n.text("名称"), text: $targetName)
                TextField("https://example.com", text: $targetURL)
                Button {
                    if model.addTarget(name: targetName, address: targetURL) {
                        targetName = ""
                        targetURL = ""
                    }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.text("添加检测站点"))
                    .disabled(targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(model.state(.connectivity) == .running)
            if let error = model.targetError { caption(error) }
        }
    }

    private func targetRow(_ target: ConnectivityTarget) -> some View {
        let result = model.connectivity[target.id]
        let status = result?.status
        let tint: Color = status.map { $0 < 400 ? .green : .orange } ?? (result == nil ? .secondary : .red)
        let value = result.map { result in
            let elapsed = result.milliseconds.map { " · \(speedText($0)) ms" } ?? ""
            return (result.status.map { "HTTP \($0)" } ?? result.error ?? L10n.text("未取得")) + elapsed
        } ?? (model.state(.connectivity) == .running ? L10n.text("检测中") : L10n.text("等待检测"))
        return HStack(spacing: 5) {
            Circle().fill(tint.opacity(result == nil ? 0.5 : 0.9)).frame(width: 6, height: 6)
            Text(target.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 1)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            if model.isCustom(target) {
                Button { model.removeTarget(target) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("移除 %@", target.name))
                    .disabled(model.state(.connectivity) == .running)
            }
        }.help(target.url.absoluteString)
    }

    private var webRTCCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch model.state(.webRTC) {
            case .idle: caption(L10n.text("待检测。刷新后比较 WebRTC 候选地址与同协议公网出口。"))
            case .running: caption(L10n.text("正在收集 WebRTC 候选地址…"))
            case .failed(let error): caption(L10n.text("检测失败。%@", error))
            case .done:
                if model.candidates.isEmpty { caption(L10n.text("本次未取得公网候选地址。")) }
                ForEach(model.candidates) { candidate in
                    HStack(spacing: 6) {
                        addressText(candidate.address)
                        badge(IPDiagnosticsModel.matchText(candidate.match),
                              color: candidate.match == .different ? .orange : (candidate.match == .matches ? .green : .secondary))
                    }
                }
                caption(L10n.text("结果来自 Nooklet 内置 WebKit 的实际连接。"))
            }
        }
    }

    private var dnsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state(.dns) {
            case .idle: caption(L10n.text("待检测。刷新后查看外部探测服务观察到的 DNS 解析器。"))
            case .running: caption(L10n.text("正在查询解析器出口…"))
            case .failed(let error): caption(L10n.text("检测失败。%@", error))
            case .done:
                if model.resolvers.isEmpty { caption(L10n.text("本次未观察到 DNS 解析器。")) }
                ForEach(model.resolvers) { resolver in
                    VStack(alignment: .leading, spacing: 3) {
                        addressText(resolver.ip)
                        let details = [resolver.country, resolver.provider].compactMap { $0 }.filter { !$0.isEmpty }
                        if !details.isEmpty { caption(details.joined(separator: " · ")) }
                    }
                }
                caption(L10n.text("请与预期使用的解析器或 VPN 配置核对。"))
            }
        }
    }

    private func addressText(_ value: String) -> some View {
        Text(model.address(value)).font(.system(.callout, design: .monospaced).weight(.medium))
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }

    private func family(_ address: String) -> some View { badge(address.contains(":") ? "IPv6" : "IPv4", color: .blue) }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }

    private func caption(_ value: String) -> some View { Text(value).font(.caption).foregroundStyle(.secondary) }
}

private struct ProbeWebView: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private struct SpeedTrace: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 4)
            guard rect.width > 0, rect.height > 0 else { return }
            var grid = Path()
            for i in 0...10 {
                let x = rect.minX + rect.width * Double(i) / 10
                grid.move(to: CGPoint(x: x, y: rect.minY))
                grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            for i in 0...4 {
                let y = rect.minY + rect.height * Double(i) / 4
                grid.move(to: CGPoint(x: rect.minX, y: y))
                grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 0.6)
            guard let maximum = values.max(), maximum > 0 else { return }
            let points = values.count == 1 ? [values[0], values[0]] : values
            var line = Path()
            for (index, value) in points.enumerated() {
                let x = rect.minX + rect.width * Double(index) / Double(points.count - 1)
                let y = rect.maxY - rect.height * value / (maximum * 1.16)
                let point = CGPoint(x: x, y: y)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            fill.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            fill.closeSubpath()
            context.fill(fill, with: .color(tint.opacity(0.13)))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}
