import AppKit
import DiskArbitration
import SwiftUI

private struct EjectableVolume: Hashable, Identifiable, Sendable {
    let url: URL
    let name: String
    let device: String
    let uuid: String?

    var id: URL { url }

    static func mounted() -> [Self] {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeUUIDStringKey,
                                         .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey]
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                              options: [.skipHiddenVolumes]) else { return [] }
        return urls.compactMap { url -> Self? in
            guard url.path != "/", !url.path.hasPrefix("/System/Volumes/"),
                  let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal == true,
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let name = DADiskGetBSDName(disk) else { return nil }
            let device = String(cString: name)
            let isInternal = (description[kDADiskDescriptionDeviceInternalKey as String] as? Bool) ?? values.volumeIsInternal
            guard values.volumeIsEjectable == true || values.volumeIsRemovable == true || isInternal == false
                    || (isInternal == nil && isExternalDevice(device)) else { return nil }
            return Self(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent,
                        device: device, uuid: values.volumeUUIDString)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isExternalDevice(_ device: String) -> Bool {
        // Synthesized APFS volumes may omit the physical device information in Disk Arbitration.
        guard let (status, data) = try? diskutil(["info", "-plist", "/dev/" + device]), status == 0,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return info["Internal"] as? Bool == false
    }

    func eject() throws {
        let (status, data) = try Self.diskutil(["eject", "/dev/" + device], mergeErrors: true)
        guard status == 0 else {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: message.isEmpty ? L10n.text("无法推出磁盘，状态码 %@。", status) : message,
            ])
        }
    }

    private static func diskutil(_ arguments: [String], mergeErrors: Bool = false) throws -> (Int32, Data) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = mergeErrors ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}

@MainActor
final class DiskEjectModel: ObservableObject {
    @Published fileprivate var volumes: [EjectableVolume] = []
    @Published private(set) var working = false
    @Published private(set) var summary = ""
    private(set) var didEject = false
    @Published private(set) var errors: [String] = []
    private var refreshTask: Task<Void, Never>?

    func refresh() {
        guard !working else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            let volumes = await Task.detached { EjectableVolume.mounted() }.value
            guard !Task.isCancelled else { return }
            self.volumes = volumes
        }
    }

    func ejectAll() async { await eject(nil) }

    fileprivate func eject(_ volume: EjectableVolume?) async {
        guard !working else { return }
        working = true
        refreshTask?.cancel()
        summary = ""
        didEject = false
        errors = []

        let result = await Task.detached {
            let targets = volume.map { [$0] } ?? EjectableVolume.mounted()
            var errors: [String] = []
            for target in targets {
                // A sibling volume may already have been ejected with the same device.
                guard EjectableVolume.mounted().contains(target) else { continue }
                do {
                    try target.eject()
                } catch {
                    errors.append("\(target.name)：\(error.localizedDescription)")
                }
            }
            let remaining = EjectableVolume.mounted()
            return (remaining, targets.count - targets.filter { remaining.contains($0) }.count, targets.isEmpty, errors)
        }.value

        volumes = result.0
        errors = result.3
        didEject = result.1 > 0
        if result.2 {
            summary = L10n.text("没有可推出的磁盘")
        } else if result.1 > 0 {
            summary = errors.isEmpty ? L10n.text("已推出 %@ 个宗卷", result.1) : L10n.text("部分磁盘未能推出")
        }
        working = false
    }
}

@MainActor
final class DiskEjectPanel: ToolPanel {
    private let model: DiskEjectModel

    init(heading: String, detail: String, model: DiskEjectModel) {
        self.model = model
        super.init(heading: heading, detail: detail)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        let hosting = NSHostingView(rootView: DiskEjectView(model: model))
        hosting.sizingOptions = []
        return hosting
    }

    override func setVisible(_ visible: Bool) {
        if visible { model.refresh() }
    }
}

@MainActor
private struct DiskEjectView: View {
    @ObservedObject var model: DiskEjectModel

    var body: some View {
        let notifications = NSWorkspace.shared.notificationCenter
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("外接磁盘与磁盘映像")).font(.headline)
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
                Button(L10n.text("刷新"), systemImage: "arrow.clockwise", action: model.refresh)
                    .disabled(model.working)
                Button(L10n.text("推出全部"), systemImage: "eject") { Task { await model.ejectAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.volumes.isEmpty || model.working)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.volumes.isEmpty {
                        ContentUnavailableView(L10n.text("暂无可推出的磁盘"), systemImage: "externaldrive")
                            .frame(maxWidth: .infinity, minHeight: 140)
                    }
                    ForEach(model.volumes) { volume in
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive").foregroundStyle(Color(nsColor: ToolboxAppearance.blue))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(volume.name).font(.subheadline.weight(.semibold))
                                Text(volume.url.path).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.text("推出"), systemImage: "eject") { Task { await model.eject(volume) } }
                                .accessibilityLabel(L10n.text("推出 %@", volume.name))
                                .disabled(model.working)
                        }
                        .padding(12)
                        .toolboxCard()
                    }
                    if !model.summary.isEmpty { Text(model.summary).font(.callout).foregroundStyle(.secondary) }
                    ForEach(Array(model.errors.enumerated()), id: \.offset) { _, error in
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(1)
            }
        }
        .onReceive(notifications.publisher(for: NSWorkspace.didMountNotification)) { _ in model.refresh() }
        .onReceive(notifications.publisher(for: NSWorkspace.didUnmountNotification)) { _ in model.refresh() }
        .onReceive(notifications.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in model.refresh() }
    }
}
