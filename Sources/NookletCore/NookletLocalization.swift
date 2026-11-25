import Foundation
import os

public enum NookletLocalization {
    private static let selection = OSAllocatedUnfairLock(initialState: AppLanguage.simplifiedChinese)

    public static var language: AppLanguage { selection.withLock { $0 } }

    public static var locale: Locale {
        Locale(identifier: language == .english ? "en" : "zh_CN")
    }

    public static func configure(_ language: AppLanguage) {
        let resolved = language.resolved()
        selection.withLock { $0 = resolved }
    }

    private static let english: Bundle? = {
        let main = Bundle.main.bundleURL
        let app = main.pathExtension == "appex"
            ? Bundle(url: main.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            : Bundle.main
        let packaged = app?.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Nooklet_NookletCore.bundle"))
        }
        return (packaged ?? .module).url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))
    }()

    public static func text(_ source: String) -> String {
        guard language == .english else { return source }
        return english?.localizedString(forKey: source, value: source, table: nil) ?? source
    }

    public static func text(_ source: String, _ arguments: Any...) -> String {
        String(format: text(source), locale: locale, arguments: arguments.map { String(describing: $0) })
    }
}
