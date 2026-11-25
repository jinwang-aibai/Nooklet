import Foundation
import NookletCore

func checkGeneralPreferences() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = try AppPaths(rootDirectory: directory)
    let store = LocalJSONStore<GeneralPreferences>(url: paths.generalPreferencesURL)

    var preferences = try store.load() ?? GeneralPreferences()
    try expectEqual(preferences.theme, .system)
    try expectEqual(preferences.language, .system)
    try expectEqual(preferences.language.resolved(preferredLanguages: ["ja", "en-GB"]), .english)
    try expectEqual(preferences.language.resolved(preferredLanguages: ["zh-Hant", "en"]), .simplifiedChinese)
    try expectEqual(preferences.language.resolved(preferredLanguages: []), .simplifiedChinese)

    preferences.language = .english
    preferences.theme = .custom
    preferences.customColor = 0xCE336B
    try store.save(preferences)
    try expectEqual(try store.load(), preferences)
    try expectEqual(preferences.language.resolved(preferredLanguages: ["zh-Hans"]), .english)

    NookletLocalization.configure(preferences.language)
    defer { NookletLocalization.configure(.simplifiedChinese) }
    try expectEqual(NookletLocalization.text("当前版本"), "Current Version")
    try expectEqual(NookletLocalization.text("将%@移到%@", "Nooklet", "Always Hidden"),
                    "Move Nooklet to Always Hidden")
    NookletLocalization.configure(.simplifiedChinese)
    try expectEqual(NookletLocalization.text("当前版本"), "当前版本")
}
