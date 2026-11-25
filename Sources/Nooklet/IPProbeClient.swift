import dnssd
import Foundation
import NookletCore

struct IPExit: Identifiable, Sendable {
    enum Route: String, Sendable {
        case domestic = "国内出口"
        case international = "国际出口"
        case internationalIPv6 = "国际出口 IPv6"
    }

    var id: Route { route }
    let route: Route
    let address: String?
    var location: String = ""
    var provider: String = ""
    var asn: Int? = nil
    var source: String = ""
}

struct DNSResolver: Identifiable, Sendable {
    let ip: String
    let country: String?
    let provider: String?
    var id: String { ip }
}

struct ConnectivityResult: Sendable {
    let status: Int?
    let milliseconds: Double?
    let error: String?
}

enum SpeedDirection: Sendable { case download, upload }
enum SpeedEvent: Sendable {
    case stage(String)
    case sample(SpeedDirection, Double)
    case latency(Double)
    case responsiveness(Double)
}

enum IPProbeClient {
    private struct Geo: Decodable {
        let ip: String
        let country: String?
        let region: String?
        let city: String?
        let isp: String?
        let asn: Int?
    }
    private struct Domestic: Decodable {
        struct Region: Decodable {
            let ip: String
            let country: String?
            let province: String?
            let city: String?
            let isp: String?
        }
        let code: Int
        let data: Region?
    }

    static func publicExits() async -> [IPExit] {
        let session = makeSession(timeout: 5)
        defer { session.invalidateAndCancel() }
        async let domestic = domesticExit(session)
        async let ipv4 = internationalExit(.international, ipv6: false, session: session)
        async let ipv6 = internationalExit(.internationalIPv6, ipv6: true, session: session)
        let results = await [domestic, ipv4, ipv6]
        return results
    }

    private static func domesticExit(_ session: URLSession) async -> IPExit {
        let source = L10n.text("米人 API")
        do {
            let url = URL(string: "https://api.mir6.com/api/ip_json?ip=myip")!
            let data = try await read(url, with: session)
            let response = try JSONDecoder().decode(Domestic.self, from: data)
            guard response.code == 200, let region = response.data,
                  let address = IPAddresses.normalizedPublic(region.ip) else { throw URLError(.cannotParseResponse) }
            return IPExit(route: .domestic, address: address,
                          location: location([region.country, region.province, region.city]), provider: region.isp ?? "", source: source)
        } catch {
            return IPExit(route: .domestic, address: nil, source: source)
        }
    }

    private static func internationalExit(_ route: IPExit.Route, ipv6: Bool, session: URLSession) async -> IPExit {
        let host = ipv6 ? "api-ipv6.ip.sb" : "api-ipv4.ip.sb"
        if let data = try? await read(URL(string: "https://\(host)/geoip")!, with: session),
           let geo = try? JSONDecoder().decode(Geo.self, from: data),
           let address = IPAddresses.normalizedPublic(geo.ip), address.contains(":") == ipv6 {
            return IPExit(route: route, address: address, location: location([geo.country, geo.region, geo.city]),
                          provider: geo.isp ?? "", asn: geo.asn, source: "IP.SB")
        }
        let fallback = ipv6 ? "api6.ipify.org" : "api.ipify.org"
        if !Task.isCancelled, let data = try? await read(URL(string: "https://\(fallback)")!, with: session),
           let text = String(data: data, encoding: .utf8),
           let address = IPAddresses.normalizedPublic(text), address.contains(":") == ipv6 {
            return IPExit(route: route, address: address, source: "ipify")
        }
        return IPExit(route: route, address: nil, source: "IP.SB / ipify")
    }

    static func connectivity(_ targets: [ConnectivityTarget]) async -> [String: ConnectivityResult] {
        let session = makeSession(timeout: 6)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: (String, ConnectivityResult).self) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<6 {
                if let target = iterator.next() { group.addTask { await test(target, session: session) } }
            }
            var results: [String: ConnectivityResult] = [:]
            for await (id, result) in group {
                results[id] = result
                if !Task.isCancelled, let target = iterator.next() { group.addTask { await test(target, session: session) } }
            }
            return results
        }
    }

    private static func test(_ target: ConnectivityTarget, session: URLSession) async -> (String, ConnectivityResult) {
        var request = URLRequest(url: target.url)
        request.httpMethod = "HEAD"
        let start = ContinuousClock.now
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (target.id, ConnectivityResult(status: http.statusCode, milliseconds: milliseconds(since: start), error: nil))
        } catch {
            let reason = (error as? URLError)?.code == .timedOut ? L10n.text("超时") : L10n.text("连接失败")
            return (target.id, ConnectivityResult(status: nil, milliseconds: nil, error: reason))
        }
    }

    static func dnsResolvers() async throws -> [DNSResolver] {
        struct Probe: Decodable {
            let testId: String
            let hostnames: [String]
        }
        struct Report: Decodable {
            struct Resolver: Decodable {
                let ip: String
                let role: String?
                let country: String?
                let org: String?
                let `operator`: String?
            }
            let resolvers: [Resolver]
        }

        let session = makeSession(timeout: 6)
        defer { session.invalidateAndCancel() }
        let start = try await read(URL(string: "https://dnsleak.dev/api/new")!, with: session, accept: "application/json")
        let probe = try JSONDecoder().decode(Probe.self, from: start)
        guard (6...64).contains(probe.testId.utf8.count), safeLabel(probe.testId) else { throw URLError(.cannotParseResponse) }

        let suffix = ".t.dnsleak.dev"
        let names = probe.hostnames.prefix(24).filter {
            $0.hasSuffix(suffix) && safeLabel(String($0.dropLast(suffix.count)))
        }
        guard !names.isEmpty else { throw URLError(.cannotParseResponse) }
        try await resolveWithSystem(names)

        let url = URL(string: "https://dnsleak.dev/api/result/\(probe.testId)")!
        let data = try await read(url, with: session, accept: "application/json")
        let report = try JSONDecoder().decode(Report.self, from: data)
        var seen = Set<String>()
        return report.resolvers.compactMap { entry in
            guard entry.role != "observer", let ip = IPAddresses.normalizedPublic(entry.ip), seen.insert(ip).inserted else { return nil }
            return DNSResolver(ip: ip, country: entry.country, provider: entry.operator ?? entry.org)
        }
    }

    private static func safeLabel(_ string: String) -> Bool {
        (1...64).contains(string.utf8.count) && string.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func resolveWithSystem(_ hosts: [String]) async throws {
        let queue = DispatchQueue(label: "dev.local.Nooklet.DNSProbe")
        var pending: [DNSServiceRef] = []
        defer { queue.sync { pending.forEach(DNSServiceRefDeallocate) } }
        for host in hosts {
            try Task.checkCancellation()
            var reference: DNSServiceRef?
            let status = DNSServiceGetAddrInfo(&reference, kDNSServiceFlagsTimeout, 0,
                DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6), host, { _, _, _, _, _, _, _, _ in }, nil)
            if status == 0, let reference {
                if DNSServiceSetDispatchQueue(reference, queue) == 0 { pending.append(reference) }
                else { DNSServiceRefDeallocate(reference) }
            }
        }
        guard !pending.isEmpty else { throw URLError(.dnsLookupFailed) }
        try await Task.sleep(for: .seconds(3))
    }

    static func speed(onEvent: @Sendable (SpeedEvent) async -> Void) async throws {
        let session = makeSession(timeout: 12)
        defer { session.invalidateAndCancel() }
        let probeURL = URL(string: "https://speed.cloudflare.com/__down?bytes=0")!
        await onEvent(.stage(L10n.text("测量空闲延迟")))
        _ = try await read(probeURL, with: session)
        var idle: [Double] = []
        for _ in 0..<3 { idle.append(try await latency(probeURL, session: session).duration) }
        await onEvent(.latency(median(idle)))

        var loaded: [Double] = []
        var firstError: (any Error)?
        for (direction, initialSize, maximumSize) in [(SpeedDirection.download, 32_000, 8_000_000), (.upload, 16_000, 3_000_000)] {
            await onEvent(.stage(direction == .download ? L10n.text("测量下载") : L10n.text("测量上传")))
            var count = initialSize
            for _ in 0..<3 {
                try Task.checkCancellation()
                do {
                    let start = ContinuousClock.now
                    async let load = loadSample(probeURL, session: session)
                    try await transfer(direction, count: count, session: session)
                    let end = ContinuousClock.now
                    let elapsed = milliseconds(since: start, until: end)
                    let rate = Double(count) * 8 / max(1, elapsed) / 1000
                    await onEvent(.sample(direction, rate))
                    if let probe = await load, probe.end <= end { loaded.append(probe.duration) }
                    let fourSeconds = Double(count) * 4_000 / max(1, elapsed)
                    count = Int(max(Double(initialSize), min(Double(maximumSize), fourSeconds)))
                } catch {
                    try Task.checkCancellation()
                    if firstError == nil { firstError = error }
                    break
                }
            }
        }
        if !loaded.isEmpty { await onEvent(.responsiveness(60_000 / max(1, median(loaded)))) }
        if let firstError { throw firstError }
    }

    private static func loadSample(_ url: URL, session: URLSession) async -> (duration: Double, end: ContinuousClock.Instant)? {
        try? await Task.sleep(for: .milliseconds(50))
        return Task.isCancelled ? nil : try? await latency(url, session: session)
    }

    private static func latency(_ url: URL, session: URLSession) async throws -> (duration: Double, end: ContinuousClock.Instant) {
        let start = ContinuousClock.now
        _ = try await read(url, with: session)
        let end = ContinuousClock.now
        return (milliseconds(since: start, until: end), end)
    }

    private static func transfer(_ direction: SpeedDirection, count: Int, session: URLSession) async throws {
        if direction == .download {
            let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(count)")!
            let (file, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            try requireSuccess(response)
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == count else {
                throw URLError(.cannotDecodeContentData)
            }
        } else {
            var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await session.upload(for: request, from: Data(repeating: 0xa7, count: count))
            try requireSuccess(response)
        }
    }

    private static func read(_ url: URL, with session: URLSession, accept: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (bytes, response) = try await session.bytes(for: request)
        try requireSuccess(response)
        var value = Data()
        for try await byte in bytes {
            guard value.count < 65_536 else { throw URLError(.cannotParseResponse) }
            value.append(byte)
        }
        return value
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Nooklet/0.3.2"]
        return URLSession(configuration: configuration, delegate: StopRedirects(), delegateQueue: nil)
    }

    private final class StopRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func location(_ parts: [String?]) -> String {
        var seen = Set<String>()
        return parts.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " · ")
    }

    private static func milliseconds(since start: ContinuousClock.Instant, until end: ContinuousClock.Instant = .now) -> Double {
        let parts = start.duration(to: end).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[index - 1] + sorted[index]) / 2 : sorted[index]
    }
}
