import XCTest
@testable import lumos

final class TaskSchedulingTests: XCTestCase {
    func testRoundedToTenMinutesRoundsToNextHourWhenNeeded() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 10, minute: 58, second: 21))!

        let rounded = TaskScheduling.roundedToTenMinutes(date, calendar: calendar)
        let components = calendar.dateComponents([.hour, .minute, .second], from: rounded)

        XCTAssertEqual(components.hour, 11)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func testReminderLeadUsesNearestPresetOption() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 2, day: 14, hour: 9, minute: 0, second: 0))!
        let remind = calendar.date(byAdding: .minute, value: -27, to: start)!

        let lead = TaskScheduling.reminderLead(startAt: start, remindAt: remind)
        XCTAssertEqual(lead, 30)
    }

    func testReminderLeadDefaultsToFiveWhenNoReminder() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(TaskScheduling.reminderLead(startAt: start, remindAt: nil), 5)
    }
}
