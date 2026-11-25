import Darwin
import Foundation
import Network

public enum LANShareError: LocalizedError {
    case invalidItem, invalidAddress

    public var errorDescription: String? {
        switch self {
        case .invalidItem: NookletLocalization.text("无法读取共享项目，请重新选择本机或外接磁盘上的文件或文件夹。")
        case .invalidAddress: NookletLocalization.text("请选择一个可用的局域网 IPv4 地址。")
        }
    }
}

/// Listener and connection state is isolated to queue after initialization.
public final class LANShare: @unchecked Sendable {
    public enum Event: Sendable {
        case ready(URL)
        case ended(String)
    }

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        let timer: DispatchSourceTimer
        var request = Data()
        var offset: Int64 = 0

        init(_ connection: NWConnection, queue: DispatchQueue) {
            self.connection = connection
            self.timer = DispatchSource.makeTimerSource(queue: queue)
        }
    }

    private enum Body {
        case bytes(Data)
        case file(LANShareItem)

        var size: Int64 {
            switch self {
            case .bytes(let data): Int64(data.count)
            case .file(let item): item.size
            }
        }
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private let queue = DispatchQueue(label: "dev.local.Nooklet.file-share", qos: .utility)
    private let listener: NWListener
    private let address: String
    private let onEvent: @Sendable (Event) -> Void
    private var roots: [(id: UUID, item: LANShareItem)] = []
    private var sharedText = ""
    private var clients: [ObjectIdentifier: Client] = [:]
    private var stopped = false

    public static func isPrivateIPv4(_ value: String) -> Bool {
        var ip = in_addr()
        guard !value.utf8.contains(0), value.withCString({ inet_pton(AF_INET, $0, &ip) }) == 1 else {
            return false
        }
        let value = UInt32(bigEndian: ip.s_addr)
        return value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8 || value >> 16 == 0xa9fe
    }

    public init(address: String, onEvent: @escaping @Sendable (Event) -> Void) throws {
        guard Self.isPrivateIPv4(address) else { throw LANShareError.invalidAddress }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
        listener = try NWListener(using: parameters)
        self.address = address
        self.onEvent = onEvent

        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                if let port = self.listener.port,
                   let url = URL(string: "http://\(self.address):\(port.rawValue)") {
                    self.onEvent(.ready(url))
                }
            case .failed(let error), .waiting(let error):
                self.finish(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) ?? connection.cancel() }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    @discardableResult
    public func setEntries(_ entries: [LANShareEntry]) -> Set<UUID> {
        var unavailable = Set<UUID>()
        let items = entries.compactMap { entry -> (UUID, LANShareItem)? in
            guard let item = try? entry.open() else { unavailable.insert(entry.id); return nil }
            return (entry.id, item)
        }
        queue.async {
            guard !self.stopped else { return }
            let available = Set(items.map { $0.0 })
            if self.roots.contains(where: { !available.contains($0.id) }) { self.disconnectAll() }
            self.roots = items
        }
        return unavailable
    }

    public func setText(_ text: String) {
        queue.async {
            guard !self.stopped else { return }
            self.sharedText = text
        }
    }

    public func stop() { queue.async { self.finish(NookletLocalization.text("共享已停止。")) } }

    private func finish(_ message: String) {
        guard !stopped else { return }
        stopped = true
        listener.cancel()
        disconnectAll()
        roots.removeAll()
        sharedText = ""
        onEvent(.ended(message))
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < 8 else { connection.cancel(); return }
        let client = Client(connection, queue: queue)
        clients[ObjectIdentifier(client)] = client
        client.timer.setEventHandler { [weak self, weak client] in
            if let client { self?.disconnect(client) }
        }
        client.timer.schedule(deadline: .now() + 10)
        client.timer.activate()
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let client else { return }
            switch state {
            case .failed, .cancelled: self?.disconnect(client)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak client] data, _, done, error in
            guard let self, let client else { return }
            if let data { client.request.append(data) }
            guard error == nil, client.request.count <= 8192 else { self.disconnect(client); return }
            if client.request.range(of: Self.headerEnd) != nil {
                self.respond(client)
            } else if done {
                self.disconnect(client)
            } else {
                self.receive(client)
            }
        }
    }

    private func respond(_ client: Client) {
        let lines = String(decoding: client.request, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD", hasLocalHost(lines),
              let path = requestPath(parts[1]) else {
            reply(to: client, status: "404 Not Found")
            return
        }
        let head = parts[0] == "HEAD"
        let site = LANShareBrowser()
        do {
            if path.isEmpty {
                let links = roots.map { (segment: $0.id.uuidString.lowercased(), item: $0.item) }
                let page = site.home(items: links, text: sharedText)
                reply(to: client, type: "text/html; charset=utf-8", body: .bytes(page), head: head)
            } else if path == ["text.txt"], !sharedText.isEmpty {
                reply(to: client, type: "text/plain; charset=utf-8", body: .bytes(Data(sharedText.utf8)), head: head,
                      disposition: "attachment; filename=shared-text.txt")
            } else if path.count >= 2, path[0] == "files", let id = UUID(uuidString: path[1]),
                      let root = roots.first(where: { $0.id == id })?.item {
                var item = root
                for component in path.dropFirst(2) {
                    guard !component.hasPrefix(".") else { throw LANShareError.invalidItem }
                    item = try item.child(named: component)
                }
                if item.isDirectory {
                    let page = site.folder(item: item, root: root.name, path: path, entries: try item.entries())
                    reply(to: client, type: "text/html; charset=utf-8", body: .bytes(page), head: head)
                } else {
                    let filename = LANShareBrowser.encodeSegment(item.name)
                    reply(to: client, type: "application/octet-stream", body: .file(item), head: head,
                          disposition: "attachment; filename*=UTF-8''\(filename)")
                }
            } else {
                reply(to: client, status: "404 Not Found")
            }
        } catch {
            reply(to: client, status: "404 Not Found")
        }
    }

    // A root-only LAN URL has no secret. Reject requests addressed to a different
    // hostname, including a site whose DNS record resolves to this private address.
    private func hasLocalHost(_ lines: [String]) -> Bool {
        guard let port = listener.port else { return false }
        let hosts = lines.dropFirst().prefix { !$0.isEmpty }.compactMap { line -> String? in
            let field = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard field.count == 2, field[0].lowercased() == "host" else { return nil }
            return field[1].trimmingCharacters(in: .whitespaces)
        }
        return hosts == ["\(address):\(port.rawValue)"]
    }

    private func requestPath(_ target: Substring) -> [String]? {
        let path = target.prefix { $0 != "?" }
        var segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.first == "/" else { return nil }
        segments.removeFirst()
        if segments.last?.isEmpty == true { segments.removeLast() }
        var result: [String] = []
        for segment in segments {
            guard let name = segment.removingPercentEncoding, LANShareItem.isChildName(name) else { return nil }
            result.append(name)
        }
        return result
    }

    private func reply(to client: Client, status: String = "200 OK", type: String = "text/plain",
                       body: Body? = nil, head: Bool = false, disposition: String? = nil) {
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body?.size ?? 0)\r\n"
        if let disposition { header += "Content-Disposition: \(disposition)\r\n" }
        header += """
            Cache-Control: no-store\r
            X-Content-Type-Options: nosniff\r
            Referrer-Policy: no-referrer\r
            Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'sha256-\(LANShareBrowser.scriptHash)'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r
            Connection: close\r
            \r

            """
        send(Data(header.utf8), to: client) { service, client in
            guard let body, !head, body.size > 0 else { service.disconnect(client); return }
            switch body {
            case .bytes(let data):
                service.send(data, to: client) { $0.disconnect($1) }
            case .file(let item):
                service.sendChunk(item, to: client)
            }
        }
    }

    private func send(_ data: Data, to client: Client, next: @escaping @Sendable (LANShare, Client) -> Void) {
        client.timer.schedule(deadline: .now() + 30)
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
            if error == nil { next(self, client) }
            else { self.disconnect(client) }
        })
    }

    private func sendChunk(_ item: LANShareItem, to client: Client) {
        guard client.offset < item.size else { disconnect(client); return }
        let length = Int(min(65_536, item.size - client.offset))
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { pread(item.descriptor, $0.baseAddress, length, client.offset) }
        guard count > 0 else { disconnect(client); return }
        data.count = count
        client.offset += Int64(count)
        send(data, to: client) { $0.sendChunk(item, to: $1) }
    }

    private func disconnectAll() {
        for client in Array(clients.values) { disconnect(client) }
    }

    private func disconnect(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.timer.cancel()
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }
}
