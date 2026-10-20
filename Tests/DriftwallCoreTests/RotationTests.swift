import Foundation
import Testing
@testable import DriftwallCore

@Suite("Rotation")
struct RotationSequencerTests {
    @Test func sequentialWrapsAround() {
        var s = RotationSequencer(items: ["a", "b", "c"])
        #expect([s.next(), s.next(), s.next(), s.next()] == ["a", "b", "c", "a"])
    }

    @Test func startsAfterRestoredCurrentItem() {
        var s = RotationSequencer(items: ["a", "b", "c"], currentID: "b")
        #expect(s.next() == "c")
    }

    @Test func skipsUnavailableItems() {
        var s = RotationSequencer(items: ["a", "b", "c"])
        let available: (WallpaperID) -> Bool = { $0 != "b" }
        #expect([s.next(isAvailable: available), s.next(isAvailable: available), s.next(isAvailable: available)] == ["a", "c", "a"])
    }

    @Test func returnsNilWhenNothingIsAvailable() {
        var s = RotationSequencer(items: ["a", "b"])
        #expect(s.next(isAvailable: { _ in false }) == nil)
        var empty = RotationSequencer(items: [])
        #expect(empty.next() == nil)
        #expect(empty.previous() == nil)
    }

    @Test func previousInSequentialMode() {
        var s = RotationSequencer(items: ["a", "b", "c"], currentID: "a")
        #expect(s.previous() == "c")
        #expect(s.previous() == "b")
    }

    @Test func shuffleNeverRepeatsImmediatelyAndIsDeterministicPerSeed() {
        var s1 = RotationSequencer(items: ["a", "b", "c", "d"], shuffle: true, seed: 42)
        var s2 = RotationSequencer(items: ["a", "b", "c", "d"], shuffle: true, seed: 42)
        var previous: WallpaperID?
        var sequence: [WallpaperID] = []
        for _ in 0..<50 {
            let id = s1.next()
            #expect(id != previous)
            previous = id
            sequence.append(id ?? "")
            #expect(s2.next() == id)
        }
        #expect(Set(sequence) == ["a", "b", "c", "d"])
    }

    @Test func shufflePreviousReturnsActualHistory() {
        var s = RotationSequencer(items: ["a", "b", "c", "d", "e"], shuffle: true, seed: 7)
        let first = s.next()
        let second = s.next()
        _ = s.next()
        #expect(s.previous() == second)
        #expect(s.previous() == first)
    }

    @Test func singleItemPlaylist() {
        var s = RotationSequencer(items: ["a"], shuffle: true, seed: 1)
        #expect(s.next() == "a")
        #expect(s.next() == "a")
    }

    @Test func updatingItemsKeepsCurrentWhenPresent() {
        var s = RotationSequencer(items: ["a", "b", "c"])
        _ = s.next() // a
        _ = s.next() // b
        s.updateItems(["c", "b", "x"])
        #expect(s.currentID == "b")
        #expect(s.next() == "x")
        s.updateItems(["y", "z"])
        #expect(s.currentID == nil)
        #expect(s.next() == "y")
    }
}

@MainActor
@Suite("Rotation scheduler")
struct RotationSchedulerTests {
    @Test func firesOnEachTickAndStopsCleanly() async throws {
        let ticker = ManualTicker()
        let scheduler = RotationScheduler(sleeper: { _ in try await ticker.sleep() })
        var fired = 0
        scheduler.onFire = { fired += 1 }
        scheduler.start(interval: 60)
        #expect(scheduler.isRunning)
        #expect(scheduler.nextFireDate != nil)

        for expected in 1...3 {
            try await waitUntil { await ticker.pendingCount == 1 }
            await ticker.tick()
            try await waitUntil { fired == expected }
        }
        scheduler.stop()
        #expect(!scheduler.isRunning)
        #expect(scheduler.nextFireDate == nil)
        await ticker.tick() // waking the cancelled task must not fire
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired == 3)
    }

    @Test func restartingNeverLeavesTwoActiveTimers() async throws {
        let ticker = ManualTicker()
        let scheduler = RotationScheduler(sleeper: { _ in try await ticker.sleep() })
        var fired = 0
        scheduler.onFire = { fired += 1 }
        scheduler.start(interval: 60)
        scheduler.start(interval: 60)
        scheduler.restart()
        try await waitUntil { await ticker.pendingCount >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        // Three tasks were started; the two cancelled ones exit before sleeping, so exactly one timer waits.
        #expect(await ticker.pendingCount == 1)
        await ticker.tick()
        try await waitUntil { fired >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired == 1)
        scheduler.stop()
    }

    @Test func intervalIsClampedToAtLeastOneSecond() {
        let scheduler = RotationScheduler(sleeper: { _ in try await Task.sleep(for: .seconds(3600)) })
        scheduler.start(interval: 0)
        #expect(scheduler.interval == 1)
        scheduler.stop()
    }

    @Test func intervalLabels() {
        #expect(RotationSettings.label(for: 60) == "1 minute")
        #expect(RotationSettings.label(for: 900) == "15 minutes")
        #expect(RotationSettings.label(for: 3600) == "1 hour")
        #expect(RotationSettings.label(for: 6 * 3600) == "6 hours")
        #expect(RotationSettings.label(for: 86400) == "1 day")
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Condition not met within \(timeout)")
    }
}
