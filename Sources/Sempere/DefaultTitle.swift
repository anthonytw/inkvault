import Foundation

/// The title a new note gets from the CLI when none is given: the date and
/// time it was created, in a format the user can change (`notes new
/// --title-format`). The app's Settings → New Notes offers the locale's date
/// and time (this format's default), the date only, or no title (`NewNoteSettings`).
///
/// A format is a Unicode date pattern (UTS #35, as `DateFormatter.dateFormat`:
/// `yyyy-MM-dd HH:mm`, `'Lecture' EEE d MMM`); literal text goes in single
/// quotes. An empty format means the locale's own medium date and short time
/// ("Oct 7, 2026 at 2:30 PM" in English, "7 oct 2026, 14:30" in Spanish).
/// Titles are labels, never keys, so two notes made in the same minute may
/// share one.
public enum DefaultTitle {
    /// Longest format used; a longer one is ignored (the locale's default is used).
    public static let maxFormatLength = 200
    /// Longest title produced (a pattern can repeat fields).
    public static let maxTitleLength = 300

    /// Some example formats, for a settings picker.
    public static let suggestions = ["", "yyyy-MM-dd HH:mm", "EEEE d MMMM yyyy", "'Note' yyyy-MM-dd", "MMM d, h:mm a"]

    /// The default title of a note created at `date`.
    ///
    /// - Parameters:
    ///   - format: a Unicode date pattern; nil, empty, too long, or one that
    ///     gives only blanks falls back to the locale's medium date and short time.
    public static func title(at date: Date, format: String?, locale: Locale = .current,
                             timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if let pattern = usable(format) {
            formatter.dateFormat = pattern
            let text = formatter.string(from: date).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(maxTitleLength)) }
        }
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// `format` when it can be used as a pattern, nil otherwise.
    public static func usable(_ format: String?) -> String? {
        guard let format, !format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              format.count <= maxFormatLength else { return nil }
        return format
    }
}
