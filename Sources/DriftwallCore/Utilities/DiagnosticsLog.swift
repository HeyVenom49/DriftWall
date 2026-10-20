import Foundation
import os

/// In-memory ring buffer of recent events shown in Settings › Diagnostics, mirrored to the unified log.
/// Nothing is sent anywhere; the user can copy the log manually.
public final class DiagnosticsLog: @unchecked Sendable {
    public enum Level: String, Sendable {
        case info, warning, error
    }

    public struct Entry: Identifiable, Sendable {
        public let id: Int
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    public static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextID = 0
    private let capacity: Int
    private let logger = Logger(subsystem: "local.driftwall", category: "app")
    /// Invoked on every new entry (on an arbitrary thread).
    public var onChange: (@Sendable () -> Void)?

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func log(_ level: Level = .info, _ category: String, _ message: String) {
        lock.lock()
        entries.append(Entry(id: nextID, date: Date(), level: level, category: category, message: message))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        let callback = onChange
        lock.unlock()

        switch level {
        case .info: logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning: logger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: logger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        callback?()
    }

    public var snapshot: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
        onChange?()
    }

    public func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        return snapshot.map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue.uppercased())] \($0.category): \($0.message)" }
            .joined(separator: "\n")
    }
}
