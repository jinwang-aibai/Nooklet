import Foundation

struct AppVersion {
    let version: String?
    let build: String?

    static let current = AppVersion(info: {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        if info["CFBundleShortVersionString"] == nil {
            // The executable launched by `swift run` has no app bundle.
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Info.plist")
            if let data = try? Data(contentsOf: source),
               let debugInfo = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                return debugInfo
            }
        }
        #endif
        return info
    }())

    init(info: [String: Any]) {
        if let official = info["CFBundleShortVersionString"] as? String,
           let beta = info["NookletBetaNumber"] as? Int, beta > 0 {
            version = "\(official)-beta.\(beta)"
        } else {
            version = info["CFBundleShortVersionString"] as? String
        }
        build = info["CFBundleVersion"] as? String
    }
}
