import Foundation
import OSLog

actor StorageService {
    enum StorageError: Error {
        case missingApplicationSupportDirectory
        case createDirectoryFailed(path: String, underlying: Error)
        case readFailed(file: String, underlying: Error)
        case moveCorruptFileFailed(file: String, underlying: Error)
        case decodeFailed(file: String, underlying: Error)
        case encodeFailed(file: String, underlying: Error)
        case writeFailed(file: String, underlying: Error)
    }

    struct LoadResult {
        let tasks: [TaskItem]
        let sessions: [FocusSession]
        let exists: Bool
        let recoveredCorruptFiles: [String]
    }

    private struct SnapshotEnvelope: Codable {
        var schemaVersion: Int
        var tasks: [TaskItem]
        var focusSessions: [FocusSession]
        var savedAt: Date
    }

    private static let corruptTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lumos", category: "storage")
    private var lastSavedRevision = 0

    private func snapshotURL() throws -> URL {
        try baseDirectory().appendingPathComponent("snapshot.json")
    }

    private func legacyTasksURL() throws -> URL {
        try baseDirectory().appendingPathComponent("tasks.json")
    }

    private func legacyFocusURL() throws -> URL {
        try baseDirectory().appendingPathComponent("focus_sessions.json")
    }

    private func baseDirectory() throws -> URL {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StorageError.missingApplicationSupportDirectory
        }
        let dir = root.appendingPathComponent("lumos", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete]
                )
            } catch {
                throw StorageError.createDirectoryFailed(path: dir.path, underlying: error)
            }
        }
        return dir
    }

    func loadAll() async throws -> LoadResult {
        var recoveredCorruptFiles: [String] = []

        if let snapshot = try loadSnapshot(recoveredCorruptFiles: &recoveredCorruptFiles) {
            return LoadResult(
                tasks: snapshot.tasks,
                sessions: snapshot.sessions,
                exists: true,
                recoveredCorruptFiles: recoveredCorruptFiles
            )
        }

        let legacy = try loadLegacy(recoveredCorruptFiles: &recoveredCorruptFiles)
        return LoadResult(
            tasks: legacy.tasks,
            sessions: legacy.sessions,
            exists: legacy.exists,
            recoveredCorruptFiles: recoveredCorruptFiles
        )
    }

    func saveAll(tasks: [TaskItem], sessions: [FocusSession], revision: Int) async throws {
        guard revision > lastSavedRevision else {
            logger.debug("Skipping stale save revision \(revision, privacy: .public), last \(self.lastSavedRevision, privacy: .public)")
            return
        }

        let url = try snapshotURL()
        let payload = SnapshotEnvelope(
            schemaVersion: 1,
            tasks: tasks,
            focusSessions: sessions,
            savedAt: Date()
        )
        let data = try encode(payload, file: url.lastPathComponent)

        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw StorageError.writeFailed(file: url.lastPathComponent, underlying: error)
        }

        lastSavedRevision = revision
    }

    private func loadSnapshot(recoveredCorruptFiles: inout [String]) throws -> (tasks: [TaskItem], sessions: [FocusSession])? {
        let url = try snapshotURL()
        guard let data = try readDataIfExists(at: url) else {
            return nil
        }

        do {
            let envelope: SnapshotEnvelope = try decode(SnapshotEnvelope.self, from: data, file: url.lastPathComponent)
            return (envelope.tasks, envelope.focusSessions)
        } catch {
            let movedPath = try quarantineCorruptFile(at: url)
            recoveredCorruptFiles.append(movedPath)
            logger.error("Recovered corrupt snapshot file by moving to \(movedPath, privacy: .public)")
            return nil
        }
    }

    private func loadLegacy(recoveredCorruptFiles: inout [String]) throws -> (tasks: [TaskItem], sessions: [FocusSession], exists: Bool) {
        let tasksURL = try legacyTasksURL()
        let focusURL = try legacyFocusURL()
        let tasksData = try readDataIfExists(at: tasksURL)
        let focusData = try readDataIfExists(at: focusURL)
        let exists = tasksData != nil || focusData != nil

        let tasks = try decodeLegacy(
            [TaskItem].self,
            data: tasksData,
            url: tasksURL,
            recoveredCorruptFiles: &recoveredCorruptFiles
        ) ?? []
        let sessions = try decodeLegacy(
            [FocusSession].self,
            data: focusData,
            url: focusURL,
            recoveredCorruptFiles: &recoveredCorruptFiles
        ) ?? []

        return (tasks, sessions, exists)
    }

    private func decodeLegacy<T: Decodable>(
        _ type: T.Type,
        data: Data?,
        url: URL,
        recoveredCorruptFiles: inout [String]
    ) throws -> T? {
        guard let data else { return nil }

        do {
            return try decode(T.self, from: data, file: url.lastPathComponent)
        } catch {
            let movedPath = try quarantineCorruptFile(at: url)
            recoveredCorruptFiles.append(movedPath)
            logger.error("Recovered corrupt legacy file \(url.lastPathComponent, privacy: .public) -> \(movedPath, privacy: .public)")
            return nil
        }
    }

    private func quarantineCorruptFile(at url: URL) throws -> String {
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let timestamp = Self.corruptTimestampFormatter.string(from: Date())
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"
        var index = 0

        while true {
            let indexSuffix = index == 0 ? "" : "-\(index)"
            let fileName = "\(baseName).corrupt-\(timestamp)\(indexSuffix)\(extSuffix)"
            let destination = directory.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: destination.path) {
                do {
                    try FileManager.default.moveItem(at: url, to: destination)
                    return destination.path
                } catch {
                    throw StorageError.moveCorruptFileFailed(file: url.lastPathComponent, underlying: error)
                }
            }
            index += 1
        }
    }

    private func readDataIfExists(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw StorageError.readFailed(file: url.lastPathComponent, underlying: error)
        }
    }

    private func encode<T: Encodable>(_ value: T, file: String) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw StorageError.encodeFailed(file: file, underlying: error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, file: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw StorageError.decodeFailed(file: file, underlying: error)
        }
    }
}
