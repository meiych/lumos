import Foundation

enum TaskType: String, Codable, CaseIterable {
    case point
    case line
    case surface
}

enum TaskStatus: String, Codable, CaseIterable {
    case idle
    case inProgress
    case paused
    case completed
    case interrupted
}

enum CompletionLevel: String, Codable, CaseIterable {
    case none
    case half
    case full
}

enum CompletionSource: String, Codable, CaseIterable {
    case manual
    case focus
}

enum TaskEndpoint {
    case start
    case end
}

struct TaskItem: Identifiable, Codable, Equatable {
    let id: UUID
    var type: TaskType
    var title: String
    var startAt: Date
    var endAt: Date?
    var createdAt: Date
    var status: TaskStatus
    var completionLevel: CompletionLevel
    var completionSource: CompletionSource
    var planDurationMinutes: Int
    var note: String
    var remindAt: Date?
    var focusEnabled: Bool

    var displayTitle: String {
        title.isEmpty ? "未命名任务" : title
    }
}

extension TaskItem {
    static func makePoint(at date: Date, title: String = "") -> TaskItem {
        TaskItem(
            id: UUID(),
            type: .point,
            title: title,
            startAt: date,
            endAt: date,
            createdAt: Date(),
            status: .idle,
            completionLevel: .none,
            completionSource: .manual,
            planDurationMinutes: 0,
            note: "",
            remindAt: nil,
            focusEnabled: false
        )
    }

    static func makeLine(startAt: Date, endAt: Date? = nil, title: String = "", planDurationMinutes: Int = 0) -> TaskItem {
        TaskItem(
            id: UUID(),
            type: .line,
            title: title,
            startAt: startAt,
            endAt: endAt,
            createdAt: Date(),
            status: .idle,
            completionLevel: .none,
            completionSource: .manual,
            planDurationMinutes: planDurationMinutes,
            note: "",
            remindAt: nil,
            focusEnabled: false
        )
    }

    static func makeSurface(startAt: Date, endAt: Date, title: String = "") -> TaskItem {
        TaskItem(
            id: UUID(),
            type: .surface,
            title: title,
            startAt: startAt,
            endAt: endAt,
            createdAt: Date(),
            status: .idle,
            completionLevel: .none,
            completionSource: .manual,
            planDurationMinutes: 0,
            note: "",
            remindAt: nil,
            focusEnabled: false
        )
    }
}
