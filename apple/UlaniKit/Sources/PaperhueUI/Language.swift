import Foundation

/// The interface language. Traditional Chinese (Taiwan) mirrors the Windows app; Chinese
/// systems of any script or region get it, everyone else English. The raw value is the
/// localization (`zh-Hant.lproj`, `en.lproj`) that the toggle asks the system-provided menus
/// to use from the next launch.
public enum Language: String, CaseIterable, Sendable {
    case chinese = "zh-Hant"
    case english = "en"

    /// The app's localizations (the `.lproj` folders of `apple/Paperhue/Paperhue`, which
    /// `LanguageTests` compares) and the language each one gets: `zh-Hans.lproj` only names
    /// the app, so Simplified Chinese systems get Chinese menus with the Chinese interface.
    static let localizations: [(localization: String, language: Language)] = [
        ("en", .english), ("zh-Hant", .chinese), ("zh-Hans", .chinese),
    ]

    /// The language whose localization macOS picks for the app's menus, app name and
    /// Bluetooth prompt (`Bundle.preferredLocalizations`), so the window starts in the same
    /// language: the first preferred language the app has a localization for (Chinese for any
    /// Chinese script or region), English when there is none (`developmentLanguage: en`).
    public static func systemDefault(preferredLanguages: [String] = Locale.preferredLanguages) -> Language {
        let available = localizations.map(\.localization)
        let picked = Bundle.preferredLocalizations(from: available, forPreferences: preferredLanguages).first
        return localizations.first { $0.localization == picked }?.language ?? .english
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
