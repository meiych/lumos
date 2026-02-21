import Foundation
import UserNotifications
import OSLog

@MainActor
final class ReminderService {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lumos", category: "reminder")
    private let reminderPrefix = "lumos-task-reminder-"
    private var lastSyncedRevision = -1

    func reconcileReminders(for tasks: [TaskItem], revision: Int) async {
        guard revision >= lastSyncedRevision else { return }
        lastSyncedRevision = revision
        let syncRevision = revision

        let activeIDs = Set(tasks.map { reminderID(for: $0.id) })
        let pending = await pendingRequests()
        guard syncRevision == lastSyncedRevision else { return }
        let staleIDs = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(reminderPrefix) && !activeIDs.contains($0) }
        if !staleIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIDs)
        }

        for task in tasks {
            guard syncRevision == lastSyncedRevision else { return }
            await syncReminder(for: task)
        }
    }

    func removeReminder(for taskID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [reminderID(for: taskID)])
    }

    private func syncReminder(for task: TaskItem) async {
        let id = reminderID(for: task.id)
        guard let remindAt = task.remindAt else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        guard remindAt > Date() else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        guard await ensureAuthorization() else {
            return
        }

        let interval = remindAt.timeIntervalSinceNow
        guard interval > 1 else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }

        let content = UNMutableNotificationContent()
        content.title = task.displayTitle
        content.body = "该开始了"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        do {
            try await add(request)
        } catch {
            logger.error("Failed to add reminder notification: \(String(describing: error), privacy: .public)")
        }
    }

    private func ensureAuthorization() async -> Bool {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return await requestAuthorization()
        @unknown default:
            return false
        }
    }

    private func reminderID(for taskID: UUID) -> String {
        reminderPrefix + taskID.uuidString
    }

    private func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    self.logger.error("Notification authorization failed: \(String(describing: error), privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }
}
