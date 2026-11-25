import AppKit
import Combine
import NookletCore
import SwiftUI

@MainActor
final class RunningAppsPanel: ToolPanel {
    private let quitNooklet: () -> Void

    init(heading: String, detail: String, quitNooklet: @escaping () -> Void) {
        self.quitNooklet = quitNooklet
        super.init(heading: heading, detail: detail)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBody() -> NSView {
        let hosting = NSHostingView(rootView: RunningAppsView(quitNooklet: quitNooklet))
        hosting.sizingOptions = []
        return hosting
    }
}

@MainActor
private struct RunningAppItem: Identifiable {
    let app: NSRunningApplication
    let bundle: RunningAppBundle
    let id: pid_t
    var identifier: String? { app.bundleIdentifier }
    var name: String { app.localizedName ?? bundle.url.deletingPathExtension().lastPathComponent }

    init(app: NSRunningApplication, bundle: RunningAppBundle) {
        self.app = app
        self.bundle = bundle
        id = app.processIdentifier
    }
}

@MainActor
private struct RunningAppGroup: Identifiable {
    let id: RunningAppBundle.GroupID
    let name: String
    let icon: NSImage
    let items: [RunningAppItem]

    func matches(_ query: String) -> Bool {
        if case .bundleIdentifier(let identifier) = id, identifier.localizedStandardContains(query) {
            return true
        }
        return name.localizedStandardContains(query) || items.contains {
            $0.name.localizedStandardContains(query) || $0.identifier?.localizedStandardContains(query) == true
        }
    }
}

@MainActor
private struct RunningAppsView: View {
    let quitNooklet: () -> Void
    @State private var groups: [RunningAppGroup] = []
    @State private var expanded: Set<RunningAppBundle.GroupID> = []
    @State private var query = ""
    @State private var notice = ""
    @State private var failed = false

    private var filtered: [RunningAppGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? groups : groups.filter { $0.matches(needle) }
    }

    var body: some View {
        let workspace = NSWorkspace.shared
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L10n.text("搜索应用或运行项"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
                Spacer()
                Button(L10n.text("刷新"), systemImage: "arrow.clockwise") { refresh(workspace.runningApplications) }
                Button(L10n.text("退出 Nooklet"), systemImage: "power", action: quitNooklet)
            }
            if !notice.isEmpty {
                Label(notice, systemImage: failed ? "exclamationmark.circle" : "info.circle")
                    .font(.callout).foregroundStyle(failed ? Color.red : Color.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if filtered.isEmpty {
                        ContentUnavailableView(query.isEmpty ? L10n.text("暂无可退出的应用") : L10n.text("没有匹配的应用"), systemImage: "macwindow")
                            .frame(maxWidth: .infinity, minHeight: 140)
                    }
                    ForEach(filtered) { group in
                        groupRow(group)
                    }
                }
                .padding(1)
            }
        }
        .onReceive(workspace.publisher(for: \.runningApplications, options: [.initial, .new])
            .receive(on: DispatchQueue.main)) { refresh($0) }
        .onReceive(workspace.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            refresh(workspace.runningApplications)
        }
    }

    private func groupRow(_ group: RunningAppGroup) -> some View {
        let hasDetails = group.items.count > 1
        let isExpanded = hasDetails && expanded.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if hasDetails {
                    Button {
                        if isExpanded {
                            expanded.remove(group.id)
                        } else {
                            expanded.insert(group.id)
                        }
                    } label: {
                        groupLabel(group, disclosure: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("%@ %@，%@ 个运行项", isExpanded ? L10n.text("收起") : L10n.text("展开"), group.name, group.items.count))
                } else {
                    groupLabel(group)
                }
                Button(hasDetails ? L10n.text("退出整组") : L10n.text("退出")) { requestQuit(group.items, name: group.name) }
                    .accessibilityLabel(hasDetails ? L10n.text("退出整组 %@", group.name) : L10n.text("退出 %@", group.name))
                    .fixedSize()
            }
            .padding(10)

            if isExpanded {
                ForEach(group.items) { item in
                    Divider().padding(.horizontal, 12)
                    itemRow(item)
                }
            }
        }
        .toolboxCard()
    }

    private func groupLabel(_ group: RunningAppGroup, disclosure: String? = nil) -> some View {
        HStack(spacing: 9) {
            Image(nsImage: group.icon)
                .resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            Text(group.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let disclosure {
                Text(L10n.text("%@ 个运行项", group.items.count))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: disclosure)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 10)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func itemRow(_ item: RunningAppItem) -> some View {
        HStack(spacing: 9) {
            if let icon = item.app.icon {
                Image(nsImage: icon).resizable().frame(width: 19, height: 19).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout).lineLimit(1)
                Text(item.identifier.map { "\($0) · PID \(item.id)" } ?? "PID \(item.id)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(L10n.text("退出")) { requestQuit([item], name: item.name) }
                .accessibilityLabel(L10n.text("退出 %@，PID %@", item.name, item.id))
                .fixedSize()
        }
        .padding(.leading, 46)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
    }

    private func refresh(_ applications: [NSRunningApplication]) {
        let excluded = Set(["com.apple.finder", Bundle.main.bundleIdentifier].compactMap { $0 })
        let apps: [RunningAppItem] = applications.compactMap { app in
            guard !app.isTerminated, app.processIdentifier != getpid(), !excluded.contains(app.bundleIdentifier ?? ""),
                  let url = app.bundleURL, let bundle = RunningAppBundle(url: url) else { return nil }
            let eligible = app.activationPolicy == .regular
                || (app.activationPolicy == .accessory && !bundle.ownerURL.path.hasPrefix("/System/"))
            return eligible ? RunningAppItem(app: app, bundle: bundle) : nil
        }

        // Read the outer bundle once per path, even when multiple helpers share it.
        let byOwner = Dictionary(grouping: apps, by: { $0.bundle.ownerURL })
        var bySoftware: [RunningAppBundle.GroupID: [RunningAppItem]] = [:]
        for (url, items) in byOwner {
            guard let first = items.first else { continue }
            let identifier = items.first(where: { $0.bundle.isOwner })?.identifier ?? Bundle(url: url)?.bundleIdentifier
            guard !excluded.contains(identifier ?? "") else { continue }
            bySoftware[first.bundle.groupID(ownerIdentifier: identifier), default: []].append(contentsOf: items)
        }

        groups = bySoftware.compactMap { id, items in
            let ordered = items.sorted { lhs, rhs in
                if lhs.bundle.isOwner != rhs.bundle.isOwner { return lhs.bundle.isOwner }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
            guard let first = ordered.first else { return nil }
            let owner = first.bundle.ownerURL
            let bundle = Bundle(url: owner)
            let name = first.bundle.isOwner ? first.name : (
                bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? owner.deletingPathExtension().lastPathComponent
            )
            let icon = (first.bundle.isOwner ? first.app.icon : nil) ?? NSWorkspace.shared.icon(forFile: owner.path)
            return RunningAppGroup(id: id, name: name, icon: icon, items: ordered)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.items[0].id < $1.items[0].id : order == .orderedAscending
        }
        expanded.formIntersection(groups.map(\.id))
    }

    private func requestQuit(_ items: [RunningAppItem], name: String) {
        var sent = 0
        var errors = 0
        for item in items where !item.app.isTerminated {
            if item.app.terminate() {
                sent += 1
            } else if !item.app.isTerminated {
                errors += 1
            }
        }
        failed = errors > 0
        if errors > 0, sent > 0 {
            notice = L10n.text("「%@」已请求 %@ 项退出，%@ 项无法发送退出请求。", name, sent, errors)
        } else if errors > 0 {
            notice = L10n.text("无法请求「%@」退出。", name)
        } else if sent > 0 {
            notice = L10n.text("已请求「%@」退出。", name)
        } else {
            notice = L10n.text("「%@」已退出。", name)
        }
        refresh(NSWorkspace.shared.runningApplications)
    }
}
