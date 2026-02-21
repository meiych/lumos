import Foundation

struct FocusSession: Identifiable, Codable, Equatable {
    let id: UUID
    var taskId: UUID?
    var startAt: Date
    var endAt: Date
    var hadPause: Bool
    var createdAt: Date
}

extension FocusSession {
    static func make(taskId: UUID?, startAt: Date, endAt: Date, hadPause: Bool) -> FocusSession {
        FocusSession(
            id: UUID(),
            taskId: taskId,
            startAt: startAt,
            endAt: endAt,
            hadPause: hadPause,
            createdAt: Date()
        )
    }
}
