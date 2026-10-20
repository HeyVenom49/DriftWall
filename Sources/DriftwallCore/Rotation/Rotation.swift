import Foundation

/// Decides which playlist item plays next. Pure value type so the ordering rules are unit-testable.
public struct RotationSequencer: Sendable {
    public private(set) var items: [WallpaperID]
    public private(set) var currentIndex: Int?
    public var shuffle: Bool
    private var backStack: [Int] = []
    private var rng: SeededGenerator

    public init(items: [WallpaperID], currentID: WallpaperID? = nil, shuffle: Bool = false, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.items = items
        self.shuffle = shuffle
        self.rng = SeededGenerator(seed: seed)
        self.currentIndex = currentID.flatMap { items.firstIndex(of: $0) }
    }

    public var currentID: WallpaperID? { currentIndex.map { items[$0] } }

    /// Replaces the item list (after a playlist edit), keeping the current item when it still exists.
    public mutating func updateItems(_ newItems: [WallpaperID]) {
        let current = currentID
        items = newItems
        currentIndex = current.flatMap { newItems.firstIndex(of: $0) }
        backStack.removeAll()
    }

    /// Moves to the next available item. Unavailable items (for example missing media) are skipped.
    /// Returns nil when no item is available.
    public mutating func next(isAvailable: (WallpaperID) -> Bool = { _ in true }) -> WallpaperID? {
        let available = items.indices.filter { isAvailable(items[$0]) }
        guard !available.isEmpty else { return nil }

        let target: Int
        if shuffle {
            let candidates = available.count > 1 ? available.filter { $0 != currentIndex } : available
            target = candidates[Int(rng.next() % UInt64(candidates.count))]
        } else {
            let start = currentIndex ?? -1
            let count = items.count
            target = (1...count).map { (start + $0) % count }.first { available.contains($0) } ?? available[0]
        }
        if let currentIndex, currentIndex != target { backStack.append(currentIndex) }
        if backStack.count > 100 { backStack.removeFirst(backStack.count - 100) }
        currentIndex = target
        return items[target]
    }

    /// Moves to the previous item: the actual previously shown item in shuffle mode,
    /// or the preceding playlist position in sequential mode.
    public mutating func previous(isAvailable: (WallpaperID) -> Bool = { _ in true }) -> WallpaperID? {
        let available = items.indices.filter { isAvailable(items[$0]) }
        guard !available.isEmpty else { return nil }

        if shuffle {
            while let candidate = backStack.popLast() {
                if candidate < items.count, isAvailable(items[candidate]) {
                    currentIndex = candidate
                    return items[candidate]
                }
            }
            return currentID.flatMap { isAvailable($0) ? $0 : nil } ?? next(isAvailable: isAvailable)
        }
        let start = currentIndex ?? 0
        let count = items.count
        let target = (1...count).map { ((start - $0) % count + count) % count }.first { available.contains($0) } ?? available[0]
        currentIndex = target
        return items[target]
    }
}

/// Small deterministic PRNG (SplitMix64) so shuffle behaviour can be reproduced in tests.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Owns the single timer task that drives automatic rotation.
///
/// Only one task can exist at a time: every `start` cancels the previous task and bumps a generation
/// counter so a stale task that wakes up late can never fire. `stop` leaves no work behind.
@MainActor
public final class RotationScheduler {
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    public private(set) var isRunning = false
    public private(set) var interval: TimeInterval = 0
    public private(set) var nextFireDate: Date?
    public var onFire: (() -> Void)?

    private var task: Task<Void, Never>?
    private var generation = 0
    private let sleeper: Sleeper
    private let now: () -> Date

    public init(sleeper: @escaping Sleeper = { seconds in try await Task.sleep(for: .seconds(seconds)) },
                now: @escaping () -> Date = Date.init) {
        self.sleeper = sleeper
        self.now = now
    }

    public func start(interval: TimeInterval) {
        stop()
        self.interval = max(1, interval)
        generation += 1
        let myGeneration = generation
        isRunning = true
        nextFireDate = now().addingTimeInterval(self.interval)
        let sleeper = self.sleeper
        let period = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleeper(period) } catch { return }
                guard let self, !Task.isCancelled, self.generation == myGeneration else { return }
                self.nextFireDate = self.now().addingTimeInterval(period)
                self.onFire?()
            }
        }
    }

    /// Restarts the countdown (used after a manual next/previous so the new item gets a full interval).
    public func restart() {
        guard isRunning else { return }
        start(interval: interval)
    }

    public func stop() {
        task?.cancel()
        task = nil
        generation += 1
        isRunning = false
        nextFireDate = nil
    }

    deinit { task?.cancel() }
}
