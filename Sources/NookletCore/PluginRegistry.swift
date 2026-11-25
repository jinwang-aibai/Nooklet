import Foundation

/// Imports only a validated declarative manifest. No executable code is copied or loaded.
public struct PluginRegistry: Sendable {
    public static let maximumManifestBytes = 65_536
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func installedPlugins() throws -> [PluginManifest] {
        try paths.ensureDirectories()
        let directories = try FileManager.default.contentsOfDirectory(
            at: paths.pluginsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var plugins: [PluginManifest] = []
        for directory in directories {
            guard try LocalFile.existsWithoutSymlink(directory) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let manifest = try manifestStore(at: manifestURL).load() else { continue }
            try manifest.validate()
            guard directory.lastPathComponent == manifest.id else { throw PluginError.identifierMismatch }
            plugins.append(manifest)
        }
        return plugins.sorted { $0.id < $1.id }
    }

    public func manifest(from source: URL) throws -> PluginManifest {
        guard source.isFileURL, try LocalFile.existsWithoutSymlink(source) else {
            throw PluginError.unsupportedSource
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let manifestURL: URL
        if attributes[.type] as? FileAttributeType == .typeDirectory, source.pathExtension == "plugin" {
            manifestURL = source.appendingPathComponent("manifest.json")
        } else if attributes[.type] as? FileAttributeType == .typeRegular, source.lastPathComponent == "manifest.json" {
            _ = try LocalFile.existsWithoutSymlink(source.deletingLastPathComponent())
            manifestURL = source
        } else {
            throw PluginError.unsupportedSource
        }
        guard let incoming = try manifestStore(at: manifestURL).load() else {
            throw PluginError.invalidManifest(NookletLocalization.text("缺少 manifest.json。"))
        }
        try incoming.validate()
        return incoming
    }

    @discardableResult
    public func importPlugin(from source: URL) throws -> PluginManifest {
        let incoming = try manifest(from: source)
        try paths.ensureDirectories()
        let destination = paths.pluginsDirectory.appendingPathComponent(incoming.id, isDirectory: true)
        try LocalFile.ensureDirectory(destination)
        let store = manifestStore(at: destination.appendingPathComponent("manifest.json"))
        if let installed = try store.load() {
            try installed.validate()
            guard installed.id == incoming.id else { throw PluginError.identifierMismatch }
            guard installed.template == incoming.template else { throw PluginError.templateChanged }
            guard let installedVersion = PluginVersion(installed.version),
                  let incomingVersion = PluginVersion(incoming.version), incomingVersion > installedVersion else {
                throw PluginError.versionNotNewer(installed: installed.version, incoming: incoming.version)
            }
        }
        // The manifest is the entire v1 package. Atomic file replacement keeps the old
        // version intact if writing fails; no partially copied executable/resources.
        try store.save(incoming)
        return incoming
    }

    private func manifestStore(at url: URL) -> LocalJSONStore<PluginManifest> {
        LocalJSONStore(url: url, maximumBytes: Self.maximumManifestBytes)
    }
}
