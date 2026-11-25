import Foundation
import NookletCore

final class PluginRegistryTests {
    private func manifest(version: String = "1.0.0", id: String = "com.example.focus", duration: Int = 1500) -> PluginManifest {
        PluginManifest(id: id, version: version, name: "专注", description: "本地计时器", defaultDurationSeconds: duration)
    }

    @discardableResult
    private func write(_ manifest: PluginManifest, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent("Source.plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }

    func testImportUpgradeAndRejectionKeepExistingVersion() throws {
        try withTemporaryDirectory { root in
            let paths = try AppPaths(rootDirectory: root.appendingPathComponent("data"))
            let registry = PluginRegistry(paths: paths)
            let source = try write(manifest(), in: root)
            try registry.importPlugin(from: source)
            try expectEqual(try registry.installedPlugins(), [manifest()])
            try write(manifest(version: "1.1.0"), in: root)
            try registry.importPlugin(from: source.appendingPathComponent("manifest.json"))
            try expectEqual(try registry.installedPlugins().first?.version, "1.1.0")
            try expectError(try registry.importPlugin(from: source))
            try write(manifest(version: "1.0.1"), in: root)
            try expectError(try registry.importPlugin(from: source))
            try write(manifest(version: "1.2.0", duration: 0), in: root)
            try expectError(try registry.importPlugin(from: source))
            try expectEqual(try registry.installedPlugins().first?.version, "1.1.0")
        }
    }

    func testImportsOnlyManifestAndNeverCopiesExecutableFiles() throws {
        try withTemporaryDirectory { root in
            let paths = try AppPaths(rootDirectory: root.appendingPathComponent("data"))
            let source = try write(manifest(), in: root)
            try Data("this must not be copied".utf8).write(to: source.appendingPathComponent("main.js"))
            try PluginRegistry(paths: paths).importPlugin(from: source)
            let destination = paths.pluginsDirectory.appendingPathComponent(manifest().id)
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["manifest.json"])
        }
    }

    func testPathTraversalAndUnsupportedCapabilitiesAreRejected() throws {
        for id in ["../escape", "com..example", "com/example", "com\\example", ".hidden", "UPPER", "中文"] {
            try expectError(try manifest(id: id).validate(), "\(id) should be rejected")
        }
        for version in ["1.0", "1.0.0-beta", "01.0.0", "1.-1.0", "9999999.0.0"] {
            try expectError(try manifest(version: version).validate())
        }
        let unsupported = PluginManifest(
            hostAPIVersion: 2, id: "com.example.timer", version: "1.0.0",
            name: "Timer", description: "", defaultDurationSeconds: 10
        )
        try expectError(try unsupported.validate())
        let executable = PluginManifest(
            id: "com.example.timer", version: "1.0.0", name: "Timer", description: "",
            template: "script", defaultDurationSeconds: 10
        )
        try expectError(try executable.validate())
    }

    func testSymlinkedManifestAndDestinationAreRejected() throws {
        try withTemporaryDirectory { root in
            let paths = try AppPaths(rootDirectory: root.appendingPathComponent("data"))
            let registry = PluginRegistry(paths: paths)
            let source = try write(manifest(), in: root)
            let sourceManifest = source.appendingPathComponent("manifest.json")
            let original = root.appendingPathComponent("original.json")
            try FileManager.default.moveItem(at: sourceManifest, to: original)
            try FileManager.default.createSymbolicLink(at: sourceManifest, withDestinationURL: original)
            try expectError(try registry.importPlugin(from: source))
            try FileManager.default.removeItem(at: sourceManifest)
            try FileManager.default.moveItem(at: original, to: sourceManifest)
            try paths.ensureDirectories()
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: paths.pluginsDirectory.appendingPathComponent(manifest().id), withDestinationURL: outside
            )
            try expectError(try registry.importPlugin(from: source))
            try expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    func testOversizedImportPreservesInstalledManifest() throws {
        try withTemporaryDirectory { root in
            let paths = try AppPaths(rootDirectory: root.appendingPathComponent("data"))
            let registry = PluginRegistry(paths: paths)
            let source = try write(manifest(), in: root)
            try registry.importPlugin(from: source)
            try Data(repeating: 32, count: PluginRegistry.maximumManifestBytes + 1)
                .write(to: source.appendingPathComponent("manifest.json"))
            try expectError(try registry.importPlugin(from: source))
            try expectEqual(try registry.installedPlugins(), [manifest()])
        }
    }

    func testNativeTemplateUpgradeCannotChangeCapabilities() throws {
        try withTemporaryDirectory { root in
            let registry = PluginRegistry(paths: try AppPaths(rootDirectory: root.appendingPathComponent("data")))
            let installed = PluginManifest(id: "com.example.status", version: "1.0.0", name: "Status",
                                           description: "", template: "systemStatus")
            let source = try write(installed, in: root)
            try expectEqual(try registry.importPlugin(from: source), installed)
            try write(PluginManifest(id: installed.id, version: "1.1.0", name: "IP",
                                     description: "", template: "ipLookup"), in: root)
            try expectError(try registry.importPlugin(from: source)) { error in
                guard case PluginError.templateChanged = error else { throw CheckFailure("Unexpected error: \(error)") }
            }
            try expectEqual(try registry.installedPlugins(), [installed])
        }
    }
}
