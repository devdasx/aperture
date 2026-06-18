import Testing
import Foundation
@testable import Aperture

/// **Part 4.4 — UTC day-key regression guard (2026-06-18).**
///
/// The chart valued history at today's spot in every negative-UTC-offset zone
/// (all of the Americas) because `DayKey.from(date:)` defaulted to
/// `Calendar.current`: a UTC-day-D candle got stored under D−1, so the
/// reconstructor's lookup missed and fell through to the current price. These
/// pin the fix: the default is UTC (so storage and lookup agree regardless of
/// device timezone), the function still keys on whatever calendar it's given,
/// and the server's authoritative `day` string parses verbatim with no
/// timezone math at all.
struct DayKeyTests {

    @Test("from(date:) buckets in UTC by default, independent of device timezone")
    func utcByDefault() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 2026-04-30 23:30 UTC — late on Apr 30 in UTC, but already May 1 in
        // Tokyo (+9). The default (UTC) must say Apr 30.
        let instant = utc.date(
            from: DateComponents(year: 2026, month: 4, day: 30, hour: 23, minute: 30)
        )!
        #expect(DayKey.from(date: instant) == 20260430)

        // And it correctly keys on whatever calendar is passed — Tokyo sees
        // May 1 — which is exactly why the default must be a fixed UTC calendar,
        // not the device's.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(DayKey.from(date: instant, calendar: tokyo) == 20260501)

        // New York (−4 in April DST) is still Apr 30 here — but the storage path
        // no longer uses it; the default UTC result is the single source.
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(DayKey.from(date: instant, calendar: ny) == 20260430)
    }

    @Test("from(dayString:) parses the server's yyyy-mm-dd verbatim")
    func fromServerDayString() {
        #expect(DayKey.from(dayString: "2026-04-30") == 20260430)
        #expect(DayKey.from(dayString: "2026-12-01") == 20261201)
        #expect(DayKey.from(dayString: "2026-01-09") == 20260109)
        // Malformed / out-of-range → nil (caller falls back to UTC epoch→day).
        #expect(DayKey.from(dayString: "garbage") == nil)
        #expect(DayKey.from(dayString: "2026-13-40") == nil)
        #expect(DayKey.from(dayString: "2026-04") == nil)
    }
}
