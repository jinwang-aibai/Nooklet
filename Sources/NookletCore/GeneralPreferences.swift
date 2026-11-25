import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "zh": return .simplifiedChinese
            case "en": return .english
            default: continue
            }
        }
        return .simplifiedChinese
    }
}

public struct GeneralPreferences: Codable, Equatable, Sendable {
    public enum Theme: String, CaseIterable, Codable, Sendable {
        case system, black, white, custom
    }

    public var language: AppLanguage = .system
    public var theme: Theme = .system
    public var customColor: UInt32 = 0x1656C8

    public init() {}
}
