import Foundation

/// The interface language. Traditional Chinese (Taiwan) mirrors the Windows app; everyone
/// else gets English. The raw value is the localization (`zh-Hant.lproj`, `en.lproj`) that
/// the system-provided menus use.
public enum Language: String, CaseIterable, Sendable {
    case chinese = "zh-Hant"
    case english = "en"

    /// Chinese when the first preferred language is Chinese (any script or region),
    /// otherwise English, also when there is none.
    public static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> Language {
        guard let first = preferredLanguages.first else { return .english }
        let code = first.lowercased().prefix { $0.isLetter }
        return code == "zh" ? .chinese : .english
    }

    /// The language the toggle switches to.
    public var other: Language {
        switch self {
        case .chinese: .english
        case .english: .chinese
        }
    }

    /// The language's own name, the same whatever the interface language is.
    public var name: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    /// The toggle's label: the language it switches to, named in that language.
    public var toggleLabel: String { other.name }
}
