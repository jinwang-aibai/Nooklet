import Foundation
import NookletCore

final class LocalStorageTests {
    func testMissingStateRoundTripAndCorruptFilePreservation() throws {
        try withTemporaryDirectory { root in
            let paths = try AppPaths(rootDirectory: root.appendingPathComponent("data"))
            try paths.ensureDirectories()
            let store = LocalJSONStore<AppConfiguration>(url: paths.configurationURL)
            try expectNil(try store.load())
            let value = AppConfiguration(selectedPluginID: "com.example.timer")
            try store.save(value)
            try expectEqual(try store.load(), value)
            let corrupt = Data("{broken".utf8)
            try corrupt.write(to: paths.configurationURL)
            try expectError(try store.load())
            try expectError(try store.save(AppConfiguration()))
            try expectEqual(try Data(contentsOf: paths.configurationURL), corrupt)
        }
    }

    func testAtomicReplacementUpdatesExistingValidState() throws {
        try withTemporaryDirectory { root in
            let store = LocalJSONStore<AppConfiguration>(url: root.appendingPathComponent("state.json"))
            try store.save(AppConfiguration(selectedPluginID: "first"))
            try store.save(AppConfiguration(selectedPluginID: "second"))
            try expectEqual(try store.load()?.selectedPluginID, "second")
        }
    }

    func testSizeLimitRejectsBeforeDecoding() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("state.json")
            try Data(repeating: 32, count: 1025).write(to: file)
            let store = LocalJSONStore<AppConfiguration>(url: file, maximumBytes: 1024)
            try expectError(try store.load()) { error in
                guard case LocalStorageError.oversizedFile = error else { throw CheckFailure("Unexpected error: \(error)") }
            }
        }
    }

    func testSymlinkedStateAndDataRootAreRejected() throws {
        try withTemporaryDirectory { root in
            let actual = root.appendingPathComponent("actual.json")
            try JSONEncoder().encode(AppConfiguration()).write(to: actual)
            let linked = root.appendingPathComponent("linked.json")
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
            try expectError(try LocalJSONStore<AppConfiguration>(url: linked).load())
            let linkedRoot = root.appendingPathComponent("linked-root")
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
            try expectError(try AppPaths(rootDirectory: linkedRoot).ensureDirectories())
        }
    }
}

func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NookletTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}
