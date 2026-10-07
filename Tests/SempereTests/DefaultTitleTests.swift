import Foundation
import XCTest
@testable import Sempere

final class DefaultTitleTests: XCTestCase {
    let posix = Locale(identifier: "en_US_POSIX")
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-07 14:05:09 UTC.
    let date = Date(timeIntervalSince1970: 1_791_381_909)

    func testPatternsAndLiteralText() {
        XCTAssertEqual(DefaultTitle.title(at: date, format: "yyyy-MM-dd HH:mm", locale: posix, timeZone: utc),
                       "2026-10-07 14:05")
        XCTAssertEqual(DefaultTitle.title(at: date, format: "'Lecture' EEE d MMM", locale: posix, timeZone: utc),
                       "Lecture Wed 7 Oct")
        XCTAssertEqual(DefaultTitle.title(at: date, format: "  HH:mm  ", locale: posix, timeZone: utc), "14:05",
                       "trimmed")
        XCTAssertEqual(DefaultTitle.title(at: date, format: "EEEE", locale: Locale(identifier: "es_ES"), timeZone: utc),
                       "miércoles")
    }

    func testEmptyOrUnusableFormatsFallBackToTheLocaleDefault() {
        let fallback = DefaultTitle.title(at: date, format: nil, locale: posix, timeZone: utc)
        XCTAssertTrue(fallback.contains("2026") && fallback.contains("Oct"), fallback)
        XCTAssertEqual(DefaultTitle.title(at: date, format: "", locale: posix, timeZone: utc), fallback)
        XCTAssertEqual(DefaultTitle.title(at: date, format: "   ", locale: posix, timeZone: utc), fallback)
        XCTAssertEqual(DefaultTitle.title(at: date, format: "' '", locale: posix, timeZone: utc), fallback,
                       "a pattern that gives nothing")
        let long = String(repeating: "y", count: DefaultTitle.maxFormatLength + 1)
        XCTAssertNil(DefaultTitle.usable(long))
        XCTAssertEqual(DefaultTitle.title(at: date, format: long, locale: posix, timeZone: utc), fallback)
        let longest = String(repeating: "yyyy", count: DefaultTitle.maxFormatLength / 4)
        XCTAssertLessThanOrEqual(DefaultTitle.title(at: date, format: longest, locale: posix, timeZone: utc).count,
                                 DefaultTitle.maxTitleLength)
    }

    func testEverySuggestionGivesATitle() {
        for format in DefaultTitle.suggestions {
            XCTAssertFalse(DefaultTitle.title(at: date, format: format, locale: posix, timeZone: utc).isEmpty, format)
        }
    }
}
