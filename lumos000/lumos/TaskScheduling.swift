import Foundation

enum TaskScheduling {
    private static let reminderLeadOptions = [5, 10, 15, 30]

    static func reminderLead(startAt: Date, remindAt: Date?) -> Int {
        guard let remindAt else { return 5 }
        let rawMinutes = Int((startAt.timeIntervalSince(remindAt) / 60).rounded())
        let normalized = max(0, rawMinutes)
        return reminderLeadOptions.min { abs($0 - normalized) < abs($1 - normalized) } ?? 5
    }

    static func roundedToTenMinutes(_ date: Date, calendar: Calendar = .current) -> Date {
        let minute = calendar.component(.minute, from: date)
        let roundedMinute = Int((Double(minute) / 10.0).rounded()) * 10
        var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        comps.minute = 0
        comps.second = 0
        comps.nanosecond = 0
        let hourDate = calendar.date(from: comps) ?? date
        if roundedMinute >= 60 {
            return calendar.date(byAdding: .hour, value: 1, to: hourDate) ?? date
        }
        return calendar.date(byAdding: .minute, value: roundedMinute, to: hourDate) ?? date
    }
}
