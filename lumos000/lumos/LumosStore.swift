import Foundation
import Combine
import OSLog

@MainActor
final class LumosStore: ObservableObject {
    private struct PendingPersistSnapshot {
        let tasks: [TaskItem]
        let sessions: [FocusSession]
        let revision: Int
    }

    private struct FocusSessionSplitResult {
        let matched: [FocusSession]
        let unmatched: [FocusSession]
    }

    @Published var tasks: [TaskItem] = []
    @Published var focusSessions: [FocusSession] = []
    @Published private(set) var lastPersistenceIssue: String?

    private let storage = StorageService()
    private let reminderService = ReminderService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lumos", category: "store")
    private var saveRevision = 0
    private var hasBootstrapped = false
    private var pendingPersist: PendingPersistSnapshot?
    private var persistWorker: Task<Void, Never>?

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        Task {
            do {
                let loaded = try await storage.loadAll()
                if loaded.exists {
                    tasks = loaded.tasks.sorted { $0.startAt < $1.startAt }
                } else {
                    tasks = seedTasks()
                }
                focusSessions = loaded.sessions.sorted { $0.startAt < $1.startAt }
                if !loaded.recoveredCorruptFiles.isEmpty {
                    let recoveredList = loaded.recoveredCorruptFiles.joined(separator: ", ")
                    let message = "Recovered corrupt local data file(s): \(recoveredList)"
                    lastPersistenceIssue = message
                    logger.error("\(message, privacy: .public)")
                }
                let reminderSnapshot = tasks
                Task {
                    await reminderService.reconcileReminders(for: reminderSnapshot, revision: 0)
                }
            } catch {
                hasBootstrapped = false
                lastPersistenceIssue = "Bootstrap failed: \(String(describing: error))"
                logger.error("Bootstrap failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func saveAll() {
        saveRevision += 1
        let revision = saveRevision
        let tasksValue = tasks
        let sessionsValue = focusSessions
        Task {
            await reminderService.reconcileReminders(for: tasksValue, revision: revision)
        }
        enqueuePersist(tasks: tasksValue, sessions: sessionsValue, revision: revision)
    }

    func flushSaves() async {
        while true {
            if persistWorker == nil, pendingPersist != nil {
                persistWorker = Task { await runPersistWorker() }
            }
            guard let worker = persistWorker else { return }
            await worker.value
        }
    }

    private func enqueuePersist(tasks: [TaskItem], sessions: [FocusSession], revision: Int) {
        pendingPersist = PendingPersistSnapshot(tasks: tasks, sessions: sessions, revision: revision)
        if persistWorker == nil {
            persistWorker = Task { await runPersistWorker() }
        }
    }

    private func runPersistWorker() async {
        while let snapshot = pendingPersist {
            pendingPersist = nil
            do {
                try await storage.saveAll(tasks: snapshot.tasks, sessions: snapshot.sessions, revision: snapshot.revision)
            } catch {
                let message = "Save failed at revision \(snapshot.revision): \(String(describing: error))"
                lastPersistenceIssue = message
                logger.error("\(message, privacy: .public)")
            }
        }
        persistWorker = nil
    }

    func createQuickPoint(at date: Date) {
        createQuickPoint(at: date, title: "")
    }

    func createQuickPoint(
        at date: Date,
        title: String,
        shouldSnap: Bool = true,
        snapMinutes: Int = 5
    ) {
        let finalDate = shouldSnap ? snap(date, toStepMinutes: snapMinutes) : date
        guard !hasPointTask(at: finalDate, excluding: nil, snapMinutes: snapMinutes) else { return }
        tasks.append(TaskItem.makePoint(at: finalDate, title: title))
        sortTasks()
        saveAll()
    }

    func updatePointTime(_ taskID: UUID, to date: Date, snapMinutes: Int = 5, persist: Bool = true) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.type == .point }) else { return }
        let snapped = snap(date, toStepMinutes: snapMinutes)
        guard !hasPointTask(at: snapped, excluding: taskID, snapMinutes: snapMinutes) else { return }
        tasks[index].startAt = snapped
        tasks[index].endAt = snapped
        sortTasks()
        if persist {
            saveAll()
        }
    }

    func updateLineTime(
        _ taskID: UUID,
        startAt: Date,
        endAt: Date?,
        snapMinutes: Int = 5,
        persist: Bool = true
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.type == .line }) else { return }
        let snappedStart = snap(startAt, toStepMinutes: snapMinutes)
        let snappedEnd = endAt.map { snap($0, toStepMinutes: snapMinutes) } ?? snappedStart
        let normalized = normalizedRange(start: snappedStart, end: snappedEnd, minimumMinutes: snapMinutes)
        tasks[index].startAt = normalized.start
        tasks[index].endAt = normalized.end
        tasks[index].planDurationMinutes = max(5, Int(normalized.end.timeIntervalSince(normalized.start) / 60))
        sortTasks()
        if persist {
            saveAll()
        }
    }

    func updateRangeTaskTime(
        _ taskID: UUID,
        startAt: Date,
        endAt: Date,
        snapMinutes: Int = 5,
        persist: Bool = true
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && ($0.type == .line || $0.type == .surface) }) else { return }
        let snappedStart = snap(startAt, toStepMinutes: snapMinutes)
        let snappedEnd = snap(endAt, toStepMinutes: snapMinutes)
        let normalized = normalizedRange(start: snappedStart, end: snappedEnd, minimumMinutes: snapMinutes)
        tasks[index].startAt = normalized.start
        tasks[index].endAt = normalized.end
        if tasks[index].type == .line {
            tasks[index].planDurationMinutes = max(5, Int(normalized.end.timeIntervalSince(normalized.start) / 60))
        }
        sortTasks()
        if persist {
            saveAll()
        }
    }

    func updateRangeTaskEndpoint(
        _ taskID: UUID,
        endpoint: TaskEndpoint,
        to date: Date,
        snapMinutes: Int = 5,
        persist: Bool = true
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && ($0.type == .line || $0.type == .surface) }) else { return }
        let step = TimeInterval(max(1, snapMinutes) * 60)
        var start = tasks[index].startAt
        var end = tasks[index].endAt ?? start.addingTimeInterval(step)
        let snapped = snap(date, toStepMinutes: snapMinutes)

        switch endpoint {
        case .start:
            start = snapped
            if start >= end {
                start = end.addingTimeInterval(-step)
            }
        case .end:
            end = snapped
            if end <= start {
                end = start.addingTimeInterval(step)
            }
        }

        tasks[index].startAt = start
        tasks[index].endAt = end
        if tasks[index].type == .line {
            tasks[index].planDurationMinutes = max(5, Int(end.timeIntervalSince(start) / 60))
        }
        sortTasks()
        if persist {
            saveAll()
        }
    }

    func convertPointToLine(_ taskID: UUID, endAt: Date, snapMinutes: Int = 5) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.type == .point }) else { return }
        let anchor = snap(tasks[index].startAt, toStepMinutes: snapMinutes)
        let target = snap(endAt, toStepMinutes: snapMinutes)
        let step = TimeInterval(max(1, snapMinutes) * 60)
        let normalized: (start: Date, end: Date)

        if target == anchor {
            normalized = (anchor, anchor.addingTimeInterval(step))
        } else if target > anchor {
            normalized = (anchor, target)
        } else {
            normalized = (target, anchor)
        }

        tasks[index].type = .line
        tasks[index].startAt = normalized.start
        tasks[index].endAt = normalized.end
        tasks[index].status = .idle
        tasks[index].completionLevel = .none
        tasks[index].completionSource = .manual
        tasks[index].planDurationMinutes = max(5, Int(normalized.end.timeIntervalSince(normalized.start) / 60))
        sortTasks()
        saveAll()
    }

    func convertLineToPoint(_ taskID: UUID, keep endpoint: TaskEndpoint, snapMinutes: Int = 5) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.type == .line }) else { return }
        let step = TimeInterval(max(1, snapMinutes) * 60)
        let lineEnd = tasks[index].endAt ?? tasks[index].startAt.addingTimeInterval(step)
        let pointDate = endpoint == .start ? tasks[index].startAt : lineEnd
        let snappedPoint = snap(pointDate, toStepMinutes: snapMinutes)
        guard !hasPointTask(at: snappedPoint, excluding: taskID, snapMinutes: snapMinutes) else { return }

        tasks[index].type = .point
        tasks[index].startAt = snappedPoint
        tasks[index].endAt = snappedPoint
        tasks[index].status = .idle
        tasks[index].completionLevel = .none
        tasks[index].completionSource = .manual
        tasks[index].planDurationMinutes = 0
        focusSessions.removeAll { $0.taskId == taskID }
        sortTasks()
        saveAll()
    }

    func convertLineToSurface(_ taskID: UUID, snapMinutes: Int = 5) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.type == .line }) else { return }
        let step = TimeInterval(max(1, snapMinutes) * 60)
        let start = snap(tasks[index].startAt, toStepMinutes: snapMinutes)
        let end = snap(tasks[index].endAt ?? start.addingTimeInterval(step), toStepMinutes: snapMinutes)
        let normalized = normalizedRange(start: start, end: end, minimumMinutes: snapMinutes)

        tasks[index].type = .surface
        tasks[index].startAt = normalized.start
        tasks[index].endAt = normalized.end
        tasks[index].status = .idle
        tasks[index].completionLevel = .none
        tasks[index].completionSource = .manual
        tasks[index].planDurationMinutes = 0
        sortTasks()
        saveAll()
    }

    func convertSurfaceToLine(_ taskID: UUID, snapMinutes: Int = 5) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.type == .surface }) else { return }
        let step = TimeInterval(max(1, snapMinutes) * 60)
        let start = snap(tasks[index].startAt, toStepMinutes: snapMinutes)
        let end = snap(tasks[index].endAt ?? start.addingTimeInterval(step), toStepMinutes: snapMinutes)
        let normalized = normalizedRange(start: start, end: end, minimumMinutes: snapMinutes)

        tasks[index].type = .line
        tasks[index].startAt = normalized.start
        tasks[index].endAt = normalized.end
        tasks[index].status = .idle
        tasks[index].completionLevel = .none
        tasks[index].completionSource = .manual
        tasks[index].planDurationMinutes = max(5, Int(normalized.end.timeIntervalSince(normalized.start) / 60))
        sortTasks()
        saveAll()
    }

    func deleteTask(_ taskID: UUID) {
        tasks.removeAll { $0.id == taskID }
        focusSessions.removeAll { $0.taskId == taskID }
        reminderService.removeReminder(for: taskID)
        saveAll()
    }

    func task(with id: UUID) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    func upsertTask(_ item: TaskItem) {
        if let idx = tasks.firstIndex(where: { $0.id == item.id }) {
            tasks[idx] = item
        } else {
            tasks.append(item)
        }
        sortTasks()
        saveAll()
    }

    func renameTask(_ taskID: UUID, title: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].title = title
        saveAll()
    }

    func togglePoint(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.type == .point }) else { return }
        let current = tasks[index].completionLevel
        tasks[index].completionLevel = (current == .full) ? .none : .full
        tasks[index].status = (tasks[index].completionLevel == .full) ? .completed : .idle
        tasks[index].completionSource = .manual
        saveAll()
    }

    func cycleLine(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID && $0.type == .line }) else { return }
        switch tasks[index].completionLevel {
        case .none:
            let coverage = focusCoverageRatio(for: tasks[index])
            if coverage > 0 {
                applyFocusCompletion(to: taskID)
            } else {
                tasks[index].completionLevel = .half
                tasks[index].status = .inProgress
                tasks[index].completionSource = .manual
            }
        case .half:
            tasks[index].completionLevel = .full
            tasks[index].status = .completed
            tasks[index].completionSource = .manual
        case .full:
            tasks[index].completionLevel = .none
            tasks[index].status = .idle
            tasks[index].completionSource = .manual
        }
        saveAll()
    }

    func addFocusSession(_ session: FocusSession, fallbackTitle: String = "") {
        guard session.endAt > session.startAt else { return }

        if let id = session.taskId {
            focusSessions.append(session)
            applyFocusCompletion(to: id)
        } else {
            let split = splitFocusSessionAcrossTasks(session)
            focusSessions.append(contentsOf: split.matched)
            focusSessions.append(contentsOf: split.unmatched)

            let matchedTaskIDs = Set(split.matched.compactMap(\.taskId))
            for matchedID in matchedTaskIDs {
                applyFocusCompletion(to: matchedID)
            }
            // Keep non-overlapping fragments instead of dropping them.
            for unmatched in split.unmatched {
                createLineFromFocus(session: unmatched, title: fallbackTitle)
            }
        }

        focusSessions.sort { $0.startAt < $1.startAt }
        saveAll()
    }

    private func createLineFromFocus(session: FocusSession, title: String) {
        var item = TaskItem.makeLine(
            startAt: session.startAt,
            endAt: session.endAt,
            title: title,
            planDurationMinutes: Int(session.endAt.timeIntervalSince(session.startAt) / 60)
        )
        item.status = .completed
        item.completionSource = .focus
        item.completionLevel = session.hadPause ? .half : .full
        tasks.append(item)
        sortTasks()
    }

    private func applyFocusCompletion(to taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let coverage = focusCoverageRatio(for: tasks[index])
        tasks[index].completionSource = .focus
        if coverage >= 1.0 {
            tasks[index].completionLevel = .full
            tasks[index].status = .completed
        } else if coverage > 0 {
            tasks[index].completionLevel = .half
            tasks[index].status = .inProgress
        } else {
            tasks[index].completionLevel = .none
            tasks[index].status = .idle
        }
    }

    private func splitFocusSessionAcrossTasks(_ session: FocusSession) -> FocusSessionSplitResult {
        guard session.taskId == nil else {
            return FocusSessionSplitResult(matched: [session], unmatched: [])
        }

        let matched = tasks
            .filter { $0.type == .line }
            .compactMap { task -> FocusSession? in
                guard let taskEnd = task.endAt else { return nil }
                let clippedStart = max(task.startAt, session.startAt)
                let clippedEnd = min(taskEnd, session.endAt)
                guard clippedEnd > clippedStart else { return nil }
                return FocusSession.make(
                    taskId: task.id,
                    startAt: clippedStart,
                    endAt: clippedEnd,
                    hadPause: session.hadPause
                )
            }
            .sorted { lhs, rhs in
                if lhs.startAt != rhs.startAt {
                    return lhs.startAt < rhs.startAt
                }
                return lhs.endAt < rhs.endAt
            }

        let unmatchedRanges = uncoveredRanges(
            sessionStart: session.startAt,
            sessionEnd: session.endAt,
            covered: matched.map { ($0.startAt, $0.endAt) }
        )
        let unmatched = unmatchedRanges.map { range in
            FocusSession.make(
                taskId: nil,
                startAt: range.0,
                endAt: range.1,
                hadPause: session.hadPause
            )
        }

        return FocusSessionSplitResult(matched: matched, unmatched: unmatched)
    }

    private func uncoveredRanges(
        sessionStart: Date,
        sessionEnd: Date,
        covered: [(Date, Date)]
    ) -> [(Date, Date)] {
        guard sessionEnd > sessionStart else { return [] }

        let clipped = covered
            .compactMap { interval -> (Date, Date)? in
                let start = max(interval.0, sessionStart)
                let end = min(interval.1, sessionEnd)
                guard end > start else { return nil }
                return (start, end)
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return lhs.0 < rhs.0
                }
                return lhs.1 < rhs.1
            }

        guard !clipped.isEmpty else {
            return [(sessionStart, sessionEnd)]
        }

        var merged: [(Date, Date)] = []
        for interval in clipped {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, interval.1))
            } else {
                merged.append(interval)
            }
        }

        var uncovered: [(Date, Date)] = []
        var cursor = sessionStart
        for interval in merged {
            if interval.0 > cursor {
                uncovered.append((cursor, interval.0))
            }
            cursor = max(cursor, interval.1)
        }
        if cursor < sessionEnd {
            uncovered.append((cursor, sessionEnd))
        }
        return uncovered
    }

    func focusCoverageRatio(for task: TaskItem) -> Double {
        guard task.type == .line, let end = task.endAt else { return 0 }
        let total = end.timeIntervalSince(task.startAt)
        guard total > 0 else { return 0 }
        let covered = focusSessions
            .filter { $0.taskId == task.id }
            .map { session in
                let s = max(session.startAt, task.startAt)
                let e = min(session.endAt, end)
                return max(0, e.timeIntervalSince(s))
            }
            .reduce(0.0) { partial, value in
                partial + value
            }
        return min(1, covered / total)
    }

    func snapToFiveMinutes(_ date: Date) -> Date {
        snap(date, toStepMinutes: 5)
    }

    func snap(_ date: Date, toStepMinutes stepMinutes: Int) -> Date {
        let calendar = Calendar.current
        let safeStep = max(1, stepMinutes)
        let stepSeconds = TimeInterval(safeStep * 60)
        let dayStart = calendar.startOfDay(for: date)
        let offset = date.timeIntervalSince(dayStart)
        // Snap to the nearest slot; midpoint (e.g. xx:05 for 10-min step) rounds up.
        let snappedOffset = (offset / stepSeconds).rounded(.toNearestOrAwayFromZero) * stepSeconds
        return dayStart.addingTimeInterval(snappedOffset)
    }

    private func normalizedRange(start: Date, end: Date, minimumMinutes: Int) -> (start: Date, end: Date) {
        let step = TimeInterval(max(1, minimumMinutes) * 60)
        if end <= start {
            return (start, start.addingTimeInterval(step))
        }
        return (start, end)
    }

    private func hasPointTask(at date: Date, excluding taskID: UUID?, snapMinutes: Int) -> Bool {
        let target = snap(date, toStepMinutes: snapMinutes)
        return tasks.contains { task in
            guard task.type == .point else { return false }
            if let taskID, task.id == taskID { return false }
            let pointSlot = snap(task.startAt, toStepMinutes: snapMinutes)
            return pointSlot == target
        }
    }

    private func sortTasks() {
        tasks.sort { $0.startAt < $1.startAt }
    }

    private func seedTasks() -> [TaskItem] {
        let now = Date()
        let calendar = Calendar.current
        let h8 = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        let h10 = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now
        let h12 = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        return [
            TaskItem.makePoint(at: h8, title: "给快递打电话"),
            TaskItem.makeLine(startAt: h10, endAt: h12, title: "prd", planDurationMinutes: 120)
        ]
    }
}
