import Foundation

/// Timestamps as they appear in remote directory listings — `ls -la` over SFTP and
/// FTP's `LIST` both use the same two Unix forms. Shared by SFTPClient/FTPClient so
/// the year-less case is handled identically in one place.
enum ListingDate {
    /// "Jun  3 04:54" — no year, so it means *this* year (or last; see `stamp`).
    private static let dateTime: DateFormatter = formatter("MMM d HH:mm")
    /// "Jun  3 2024" — anything older than ~6 months carries its year.
    private static let dateYear: DateFormatter = formatter("MMM d yyyy")

    private static func formatter(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f
    }

    /// Parse one listing timestamp. Whitespace is collapsed first — `ls` pads the
    /// day to two columns ("Jun  3"), which neither format string tolerates.
    /// Returns `.distantPast` for anything unrecognised so sorting stays total.
    static func parse(_ raw: String, now: Date = Date()) -> Date {
        let s = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if let timed = dateTime.date(from: s) { return stamp(timed, now: now) }
        return dateYear.date(from: s) ?? .distantPast
    }

    /// Apply the current year to a year-less `ls` timestamp; if that puts it in the
    /// future, it belongs to last year (e.g. a Dec date read in January).
    static func stamp(_ d: Date, now: Date = Date()) -> Date {
        let cal = Calendar(identifier: .gregorian)
        var c = cal.dateComponents([.month, .day, .hour, .minute], from: d)
        c.year = cal.component(.year, from: now)
        guard let stamped = cal.date(from: c) else { return d }
        return stamped > now ? (cal.date(byAdding: .year, value: -1, to: stamped) ?? stamped) : stamped
    }
}
