import Foundation
import Sempere

/// The title a new note gets when none is typed: its date and time, in the
/// format stored in `UserDefaults` under `Sempere.defaultTitleFormat` (a
/// Unicode date pattern; unset or empty: the locale's medium date and short
/// time). The Settings panel (task E6) will expose it; the logic is the
/// package's `DefaultTitle`, which `sempere notes new` uses too.
enum DefaultTitlePreference {
    static let defaultsKey = "Sempere.defaultTitleFormat"

    /// The stored format, nil when unset.
    static func format(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: defaultsKey)
    }

    /// Stores `format` (nil or empty: back to the locale's default).
    static func setFormat(_ format: String?, in defaults: UserDefaults = .standard) {
        if let format, DefaultTitle.usable(format) != nil {
            defaults.set(format, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// The default title of a note created at `date`.
    static func title(at date: Date = Date(), defaults: UserDefaults = .standard, locale: Locale = .current,
                      timeZone: TimeZone = .current) -> String {
        DefaultTitle.title(at: date, format: format(in: defaults), locale: locale, timeZone: timeZone)
    }
}
