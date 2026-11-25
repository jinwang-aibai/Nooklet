import Foundation
import NookletCore
import os

func checkLANSharePersistence() throws {
    try withTemporaryDirectory { root in
        let file = root.appendingPathComponent("测试.txt")
        try Data().write(to: file)
        let selectedFile = try LANShareEntry(url: file)
        let selectedFolder = try LANShareEntry(url: root)
        try expectFalse(selectedFile.isDirectory)
        try expect(selectedFolder.isDirectory)
        let saved = root.appendingPathComponent("lan-share.json")
        let store = LocalJSONStore<LANShareSettings>(url: saved)
        let legacy: [String: Any] = ["selection": ["file": ["_0": file.absoluteString]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: saved)
        try expectEqual(try store.load()?.entries.map(\.url), [file])
        let mixed = LANShareSettings(entries: [selectedFolder, selectedFile], text: "剪贴板\n第二行")
        try store.save(mixed)
        try expectEqual(try LocalJSONStore<LANShareSettings>(url: saved).load(), mixed)
        try store.save(LANShareSettings())
        try expectEqual(try store.load(), LANShareSettings())
        try expectError(try LANShareEntry(url: root.appendingPathComponent("missing")))
    }
}

func checkLANShareHTTP() throws {
    guard let address = try IPAddresses.local().first(where: { !$0.isIPv6 && LANShare.isPrivateIPv4($0.address) }) else {
        throw CheckFailure("The HTTP check needs a private IPv4 address on an active interface.")
    }
    try withTemporaryDirectory { root in
        let folder = root.appendingPathComponent("共享")
        let nested = folder.appendingPathComponent("子目录")
        let name = "a#<b>&.txt"
        let file = nested.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let fileBytes = Data((0..<250_000).map { UInt8(truncatingIfNeeded: $0) })
        try fileBytes.write(to: file)
        let privateFile = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: privateFile)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("outside-link"), withDestinationURL: privateFile)
        let ready = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        let link = OSAllocatedUnfairLock(initialState: Optional<URL>.none)
        let service = try LANShare(address: address.address) { event in
            switch event {
            case .ready(let url):
                link.withLock { $0 = url }
                ready.signal()
            case .ended:
                ready.signal()
                ended.signal()
            }
        }
        defer { service.stop() }
        try expectEqual(ready.wait(timeout: .now() + 5), .success)
        guard let url = link.withLock({ $0 }) else { throw CheckFailure("LAN listener did not start") }

        let responseFile = root.appendingPathComponent("response")
        func request(_ target: String, head: Bool = false, allowFailure: Bool = false, host: String? = nil) throws -> (String, Data) {
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["--silent", "--show-error", "--noproxy", "*", "--path-as-is", "--max-time", "5",
                              "--dump-header", "-", "--output", responseFile.path]
                + (head ? ["--head"] : []) + (host.map { ["--header", "Host: \($0)"] } ?? []) + [target]
            let headers = Pipe()
            curl.standardOutput = headers
            curl.standardError = FileHandle.nullDevice
            try curl.run()
            let header = String(decoding: headers.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            curl.waitUntilExit()
            if allowFailure {
                try expect(curl.terminationStatus != 0)
                return (header, Data())
            }
            guard curl.terminationStatus == 0 else { throw CheckFailure("curl exit \(curl.terminationStatus) for \(target)") }
            return (header, try Data(contentsOf: responseFile))
        }

        let base = url.absoluteString
        guard let port = url.port else { throw CheckFailure("Missing LAN port") }
        try expectEqual(base, "http://\(address.address):\(port)")
        try expect(try request(base, host: "wrong.example:\(port)").0.hasPrefix("HTTP/1.1 404"))
        try expect(String(decoding: request(base).1, as: UTF8.self).contains("等待共享内容"))
        let text = "\n剪贴板\n</textarea><script>这是文本</script>"
        let directFile = try LANShareEntry(url: file)
        let folderEntry = try LANShareEntry(url: folder)
        let unavailableURL = root.appendingPathComponent("missing.txt")
        try Data().write(to: unavailableURL)
        let unavailable = try LANShareEntry(url: unavailableURL)
        try FileManager.default.removeItem(at: unavailableURL)
        try expectEqual(service.setEntries([directFile, folderEntry, unavailable]), Set([unavailable.id]))
        service.setText(text)
        let (headers, body) = try request(base)
        let home = String(decoding: body, as: UTF8.self)
        try expect(home.contains("a#&lt;b&gt;&amp;.txt") && home.contains("共享文本"))
        try expect(home.contains("&lt;/textarea&gt;&lt;script&gt;") && headers.contains("script-src 'sha256-"))
        let note = try request(base + "/text.txt")
        try expectEqual(note.1, Data(text.utf8))

        let fileURL = base + "/files/" + directFile.id.uuidString.lowercased()
        let fileResponse = try request(fileURL)
        try expect(fileResponse.0.contains("Content-Disposition: attachment;"))
        try expect(fileResponse.1 == fileBytes)
        try expect(try request(fileURL, head: true).0.contains("Content-Length: \(fileBytes.count)"))

        let folderURL = base + "/files/" + folderEntry.id.uuidString.lowercased()
        let listing = String(decoding: try request(folderURL).1, as: UTF8.self)
        try expect(listing.contains("子目录") && listing.contains("共享首页"))
        try expectFalse(listing.contains("outside-link"))
        try expectEqual(try folderEntry.children(at: []).map(\.name), ["子目录"])
        let childBase = folderURL + "/%E5%AD%90%E7%9B%AE%E5%BD%95/"
        let children = String(decoding: try request(childBase).1, as: UTF8.self)
        try expect(children.contains("a#&lt;b&gt;&amp;.txt"))
        try expect(try request(childBase + "a%23%3Cb%3E%26.txt").1 == fileBytes)
        for path in ["outside-link", "%2e%2e/outside.txt", "%2e%2e%2foutside.txt", "%00"] {
            try expect(try request(folderURL + "/" + path).0.hasPrefix("HTTP/1.1 404"))
        }
        try expect(try request(base + "/unknown").0.hasPrefix("HTTP/1.1 404"))
        service.setEntries([folderEntry])
        try expect(try request(fileURL).0.hasPrefix("HTTP/1.1 404"))
        try expectEqual(try request(base + "/text.txt").1, Data(text.utf8))
        service.setEntries([])
        service.setText("")
        try expect(String(decoding: request(base).1, as: UTF8.self).contains("等待共享内容"))
        service.stop()
        try expectEqual(ended.wait(timeout: .now() + 5), .success)
        _ = try request(base, allowFailure: true)
    }
}
