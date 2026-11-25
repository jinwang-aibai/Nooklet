import Foundation

package struct RunningAppBundle {
    package enum GroupID: Hashable {
        case bundleIdentifier(String)
        case path(String)
    }

    package let url: URL
    package let ownerURL: URL
    package var isOwner: Bool { url.path == ownerURL.path }

    package init?(url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else { return nil }

        // An app nested under another app's Contents belongs to the outer bundle.
        var owner = url
        var directory = url.deletingLastPathComponent()
        while directory.path != "/", !directory.path.isEmpty {
            let parent = directory.deletingLastPathComponent()
            if directory.lastPathComponent == "Contents", parent.pathExtension.lowercased() == "app" {
                owner = parent
            }
            directory = parent
        }
        self.url = url.resolvingSymlinksInPath()
        ownerURL = owner.resolvingSymlinksInPath()
    }

    package func groupID(ownerIdentifier: String?) -> GroupID {
        if let ownerIdentifier, !ownerIdentifier.isEmpty {
            return .bundleIdentifier(ownerIdentifier)
        }
        return .path(ownerURL.path)
    }
}
