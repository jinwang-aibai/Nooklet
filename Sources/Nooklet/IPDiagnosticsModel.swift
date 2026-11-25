import AppKit
import Combine
import NookletCore

@MainActor
final class IPDiagnosticsModel: ObservableObject {
    enum Check: Hashable { case ip, speed, connectivity, webRTC, dns }
    enum State: Equatable { case idle, running, done, failed(String) }
    struct Candidate: Identifiable {
        let address: String
        let match: WebRTCMatch
        var id: String { address }
    }

    @Published private(set) var local: [InterfaceAddress] = []
    @Published private(set) var localError: String?
    @Published private(set) var exits: [IPExit] = []
    @Published private(set) var targets: [ConnectivityTarget] = []
    @Published private(set) var connectivity: [String: ConnectivityResult] = [:]
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var resolvers: [DNSResolver] = []
    @Published private(set) var webRTCProbe: WebRTCProbe?
    @Published private(set) var speedStage = ""
    @Published private(set) var download: [Double] = []
    @Published private(set) var upload: [Double] = []
    @Published private(set) var latency: Double?
    @Published private(set) var responsiveness: Double?
    @Published private(set) var hidden = false
    @Published private(set) var copied = false
    @Published private(set) var targetError: String?
    @Published private var states: [Check: State] = [:]

    private var tasks: [Check: Task<Void, Never>] = [:]
    private let store: LocalJSONStore<[ConnectivityTarget]>

    private static let standard = [
        ("wechat", "WeChat", "https://weixin.qq.com/"), ("google", "Google", "https://www.google.com/"),
        ("cloudflare", "Cloudflare", "https://www.cloudflare.com/"), ("youtube", "YouTube", "https://www.youtube.com/"),
        ("github", "GitHub", "https://github.com/"), ("chatgpt", "ChatGPT", "https://chatgpt.com/"),
    ].compactMap { ConnectivityTarget(name: $0.1, address: $0.2, id: $0.0) }

    init(paths: AppPaths) {
        store = LocalJSONStore(url: paths.rootDirectory.appendingPathComponent("ip-targets.json"))
        targets = Self.standard
        do {
            let custom = try store.load() ?? []
            var ids = Set(Self.standard.map(\.id))
            targets += custom.compactMap {
                guard ids.insert($0.id).inserted else { return nil }
                return ConnectivityTarget(name: $0.name, address: $0.url.absoluteString, id: $0.id)
            }
        } catch { targetError = L10n.text("自定义站点读取失败。%@", error.localizedDescription) }
        readLocal()
    }

    func state(_ check: Check) -> State { states[check] ?? .idle }

    func run(_ check: Check) {
        if state(check) == .running { cancel(check); return }
        copied = false
        states[check] = .running
        switch check {
        case .ip: readLocal(); exits = []
        case .speed: download = []; upload = []; latency = nil; responsiveness = nil; speedStage = ""
        case .connectivity: connectivity = [:]
        case .webRTC: candidates = []
        case .dns: resolvers = []
        }
        tasks[check] = Task { [weak self] in
            guard let self else { return }
            do {
                try await perform(check)
                try Task.checkCancellation()
                states[check] = .done
            } catch {
                guard !Task.isCancelled else { return }
                states[check] = .failed(error.localizedDescription)
            }
            tasks[check] = nil
            if check == .webRTC { webRTCProbe = nil }
        }
    }

    func cancelAll() {
        for check in Array(tasks.keys) { cancel(check) }
    }

    private func cancel(_ check: Check) {
        tasks.removeValue(forKey: check)?.cancel()
        states[check] = .idle
        if check == .webRTC { webRTCProbe = nil }
    }

    private func perform(_ check: Check) async throws {
        switch check {
        case .ip:
            let result = await IPProbeClient.publicExits()
            try Task.checkCancellation()
            exits = result
        case .speed:
            try await IPProbeClient.speed { [weak self] event in
                guard !Task.isCancelled else { return }
                await self?.record(event)
            }
        case .connectivity:
            let result = await IPProbeClient.connectivity(targets)
            try Task.checkCancellation()
            connectivity = result
        case .webRTC:
            let probe = WebRTCProbe()
            webRTCProbe = probe
            async let references = IPProbeClient.publicExits()
            let result = try await probe.collect()
            let addresses = await references.compactMap(\.address)
            try Task.checkCancellation()
            candidates = result.map { Candidate(address: $0, match: IPAddresses.webRTCMatch($0, with: addresses)) }
        case .dns:
            let result = try await IPProbeClient.dnsResolvers()
            try Task.checkCancellation()
            resolvers = result
        }
    }

    private func record(_ event: SpeedEvent) {
        guard !Task.isCancelled, state(.speed) == .running else { return }
        switch event {
        case .stage(let title): speedStage = title
        case .sample(.download, let value): download.append(value)
        case .sample(.upload, let value): upload.append(value)
        case .latency(let value): latency = value
        case .responsiveness(let value): responsiveness = value
        }
    }

    func readLocal() {
        do {
            let all = try IPAddresses.local()
            let useful = all.filter { !$0.address.hasPrefix("fe80:") || $0.interface.hasPrefix("en") }
            local = useful.isEmpty ? all : useful
            localError = nil
        }
        catch { local = []; localError = error.localizedDescription }
    }

    func addTarget(name: String, address: String) -> Bool {
        guard let target = ConnectivityTarget(name: name, address: address) else {
            targetError = L10n.text("请填写名称和有效的 HTTPS 网址。")
            return false
        }
        guard !targets.contains(where: { $0.url == target.url }) else {
            targetError = L10n.text("这个网址已在检测列表中。")
            return false
        }
        return saveTargets(targets + [target])
    }

    func isCustom(_ target: ConnectivityTarget) -> Bool { !Self.standard.contains { $0.id == target.id } }

    func removeTarget(_ target: ConnectivityTarget) {
        if isCustom(target), saveTargets(targets.filter { $0.id != target.id }) {
            connectivity.removeValue(forKey: target.id)
        }
    }

    private func saveTargets(_ updated: [ConnectivityTarget]) -> Bool {
        do {
            try store.save(updated.filter(isCustom))
            targets = updated
            targetError = nil
            return true
        } catch {
            targetError = L10n.text("无法保存站点。%@", error.localizedDescription)
            return false
        }
    }

    func toggleHidden() {
        hidden.toggle()
        copied = false
    }

    func address(_ value: String) -> String { hidden ? "••••••" : value }

    func copyResults() {
        var lines = [L10n.text("Nooklet · IP 检测")]
        for exit in exits {
            lines.append([L10n.text(exit.route.rawValue), exit.address.map(address) ?? L10n.text("未取得"), exit.location, exit.provider]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        }
        if !local.isEmpty {
            lines.append(L10n.text("本地局域网 IP"))
            lines += local.map { "\($0.interface)  \(address($0.address))" }
        }
        if let value = download.last { lines.append(L10n.text("下载 %@ Mbps", speedText(value))) }
        if let value = upload.last { lines.append(L10n.text("上传 %@ Mbps", speedText(value))) }
        if let latency { lines.append(L10n.text("空闲延迟 %@ ms", speedText(latency))) }
        if let responsiveness { lines.append(L10n.text("负载响应性 %@ RPM", speedText(responsiveness))) }
        for target in targets {
            if let result = connectivity[target.id] {
                let status = result.status.map { "HTTP \($0)" } ?? result.error ?? L10n.text("未取得")
                let timing = result.milliseconds.map { " · \(speedText($0)) ms" } ?? ""
                lines.append("\(target.name) · \(status)\(timing)")
            }
        }
        if !candidates.isEmpty { lines += candidates.map { "WebRTC · \(address($0.address)) · \(Self.matchText($0.match))" } }
        if !resolvers.isEmpty {
            lines += resolvers.map { "DNS · \(address($0.ip))" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
    }

    static func matchText(_ match: WebRTCMatch) -> String {
        switch match {
        case .matches: L10n.text("与公网出口一致")
        case .different: L10n.text("与已测公网出口不同")
        case .unverified: L10n.text("同协议公网结果缺失")
        }
    }
}

func speedText(_ number: Double) -> String {
    number.formatted(.number.precision(.fractionLength(number >= 100 ? 0 : 1)))
}
