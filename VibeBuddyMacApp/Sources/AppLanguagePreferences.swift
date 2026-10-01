import SwiftUI

/// Use the app's language preference so SwiftUI, AppKit and the Kit resource
/// bundle all resolve the same language on the next launch. Changing only the
/// SwiftUI locale would leave notifications and String(localized:) unchanged.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    static func selected(in defaults: UserDefaults = .standard) -> AppLanguage {
        let languages = defaults.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        let preferred = Bundle.preferredLocalizations(
            from: allCases.map(\.rawValue), forPreferences: languages).first
        return preferred.flatMap(Self.init(rawValue:)) ?? .english
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set([rawValue], forKey: "AppleLanguages")
    }
}

struct AppLanguagePreferences: View {
    @State private var language = AppLanguage.selected()

    var body: some View {
        SettingsSection("Language",
                        footnote: "Changes are saved automatically. Quit and reopen VibeBuddy to apply the language to all windows, menus and notifications.") {
            SettingsRow("App language") {
                Picker("App language", selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("appLanguage")
                .onChange(of: language) { _, newValue in newValue.save() }
            }
        }
    }
}
