import Foundation

nonisolated public enum L10n {
    public static func string(_ key: String, defaultValue: String) -> String {
        NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: defaultValue,
            comment: ""
        )
    }

    public static func format(_ key: String, defaultValue: String, _ arguments: any CVarArg...) -> String {
        String(
            format: string(key, defaultValue: defaultValue),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
