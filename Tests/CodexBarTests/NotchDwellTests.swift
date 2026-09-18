import Foundation
import Testing
@testable import CodexBar

struct NotchDwellTests {
    @Test
    func `reshow honors the tier floor when the remainder is smaller`() {
        let start = Date(timeIntervalSince1970: 9000)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "info"), now: start)
        queue.enqueue(
            Self.event(type: .accessRequest, title: "critical"), now: start.addingTimeInterval(9))

        // Preempted with 1s left; the 5s T1 floor applies on reshow.
        queue.advance(now: start.addingTimeInterval(24))
        #expect(queue.active?.title == "info")
        #expect(queue.activeUntil == start.addingTimeInterval(29))
    }

    @Test
    func `total dwell caps reshow length then retires the item`() {
        // Distinct providers keep every show under the frequency cap, so this
        // trace isolates the 2x total-dwell rule on one T2 victim.
        let start = Date(timeIntervalSince1970: 9100)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(provider: "P0", type: .accessRequest, title: "victim"), now: start)
        queue.enqueue(Self.event(provider: "P1", type: .accessRequest, title: "A"), now: start.addingTimeInterval(9))
        queue.enqueue(Self.event(provider: "P2", type: .completed, title: "R"), now: start.addingTimeInterval(9))
        // Two fresh criticals have shown, so fairness serves R next and resets.
        queue.advance(now: start.addingTimeInterval(24))
        #expect(queue.active?.title == "R")
        #expect(queue.consecutiveCriticalShows == 0)

        queue.advance(now: start.addingTimeInterval(34))
        #expect(queue.active?.title == "victim")
        queue.enqueue(Self.event(provider: "P3", type: .accessRequest, title: "B"), now: start.addingTimeInterval(43))
        queue.advance(now: start.addingTimeInterval(58))
        #expect(queue.active?.title == "victim")

        queue.enqueue(Self.event(provider: "P4", type: .accessRequest, title: "C"), now: start.addingTimeInterval(67))
        queue.advance(now: start.addingTimeInterval(82))
        // 27s shown of a 30s budget: the reshow clamps to 3s, under the floor.
        #expect(queue.active?.title == "victim")
        #expect(queue.activeUntil == start.addingTimeInterval(85))

        queue.enqueue(Self.event(provider: "P5", type: .accessRequest, title: "D"), now: start.addingTimeInterval(84))
        queue.advance(now: start.addingTimeInterval(99))
        #expect(queue.active?.title == "victim")
        #expect(queue.activeUntil == start.addingTimeInterval(100))

        // 29.5s shown: the 0.5s allowance is below the minimum, so the item
        // retains instead of reshipping. Empty pending means no fairness debt.
        queue.enqueue(Self.event(provider: "P6", type: .accessRequest, title: "E"), now: start.addingTimeInterval(99.5))
        queue.advance(now: start.addingTimeInterval(114.5))
        #expect(queue.active == nil)
        #expect(queue.retained.map(\.title) == ["A", "R", "B", "C", "D", "E", "victim"])
        #expect(queue.unreadCount == 7)
    }

    @Test
    func `fairness serves the oldest waiting info after two fresh criticals`() {
        let start = Date(timeIntervalSince1970: 9200)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(provider: "P1", type: .accessRequest, title: "A"), now: start)
        queue.enqueue(Self.event(provider: "P2", type: .completed, title: "info"), now: start)
        queue.enqueue(Self.event(provider: "P3", type: .accessRequest, title: "B"), now: start)
        #expect(queue.consecutiveCriticalShows == 2)

        queue.advance(now: start.addingTimeInterval(15))
        #expect(queue.active?.title == "info")
        #expect(queue.consecutiveCriticalShows == 0)
    }

    @Test
    func `fairness counter resets when the queue drains`() {
        let start = Date(timeIntervalSince1970: 9250)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .accessRequest, title: "only"), now: start)
        #expect(queue.consecutiveCriticalShows == 1)
        queue.advance(now: start.addingTimeInterval(15))
        #expect(queue.active == nil)
        #expect(queue.consecutiveCriticalShows == 0)
    }

    @Test
    func `preemption is suppressed while fairness owes a waiting info`() {
        let start = Date(timeIntervalSince1970: 9300)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(provider: "P1", type: .accessRequest, title: "A"), now: start)
        queue.enqueue(Self.event(provider: "P2", type: .completed, title: "info"), now: start)
        queue.enqueue(Self.event(provider: "P3", type: .accessRequest, title: "B"), now: start)
        queue.enqueue(Self.event(provider: "P4", type: .accessRequest, title: "C"), now: start)

        #expect(queue.active?.title == "B")
        #expect(queue.pending.map(\.title) == ["A", "C", "info"])
        #expect(queue.consecutiveCriticalShows == 2)
    }

    @Test
    func `frequency cap overflows the fourth banner to retained`() {
        let start = Date(timeIntervalSince1970: 9400)
        var queue = NotchNotificationQueue()
        for index in 1...4 {
            queue.enqueue(Self.event(type: .completed, title: "e\(index)"), now: start)
        }
        queue.advance(now: start.addingTimeInterval(10))
        #expect(queue.active?.title == "e2")
        queue.advance(now: start.addingTimeInterval(20))
        #expect(queue.active?.title == "e3")
        // Three same-provider shows inside 60s: e4 overflows instead of showing.
        queue.advance(now: start.addingTimeInterval(30))
        #expect(queue.active == nil)
        #expect(queue.retained.map(\.title) == ["e1", "e2", "e3", "e4"])
        #expect(queue.unreadCount == 4)

        // The window slides: a later arrival shows again.
        queue.enqueue(Self.event(type: .completed, title: "e5"), now: start.addingTimeInterval(61))
        #expect(queue.active?.title == "e5")
    }

    @Test
    func `identical arrivals coalesce into the active banner`() {
        let start = Date(timeIntervalSince1970: 9500)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "same"), now: start)
        queue.enqueue(Self.event(type: .completed, title: "same"), now: start.addingTimeInterval(1))
        queue.enqueue(Self.event(type: .completed, title: "same"), now: start.addingTimeInterval(2))

        #expect(queue.active?.count == 3)
        #expect(queue.pending.isEmpty)
        queue.advance(now: start.addingTimeInterval(10))
        #expect(queue.retained.map(\.count) == [3])
        #expect(queue.unreadCount == 1)
    }

    @Test
    func `overflow merges into an identical retained entry`() {
        // A2 arrives while B is active, so it queues instead of coalescing;
        // at t=30 the frequency cap trips and it merges into retained A.
        // D trips on the same cascade and appends.
        let start = Date(timeIntervalSince1970: 9600)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "A"), now: start)
        queue.enqueue(Self.event(type: .completed, title: "B"), now: start.addingTimeInterval(1))
        queue.enqueue(Self.event(type: .completed, title: "C"), now: start.addingTimeInterval(2))
        queue.advance(now: start.addingTimeInterval(10))
        queue.enqueue(Self.event(type: .completed, title: "A"), now: start.addingTimeInterval(11))
        queue.enqueue(Self.event(type: .completed, title: "D"), now: start.addingTimeInterval(12))
        queue.advance(now: start.addingTimeInterval(20))
        queue.advance(now: start.addingTimeInterval(30))

        #expect(queue.active == nil)
        #expect(queue.retained.map(\.title) == ["A", "B", "C", "D"])
        #expect(queue.retained.first?.count == 2)
        #expect(queue.unreadCount == 5)
    }

    @Test
    func `evicted pending items count once on eviction`() {
        let start = Date(timeIntervalSince1970: 9700)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "active"), now: start)
        for index in 0..<(NotchNotificationQueue.maxPendingCount + 2) {
            queue.enqueue(Self.event(type: .completed, title: "info-\(index)"), now: start)
        }

        #expect(queue.pending.count == NotchNotificationQueue.maxPendingCount)
        #expect(queue.unreadCount == 2)
    }

    @Test
    func `freeze pauses the countdown and collapse extends the window`() {
        let start = Date(timeIntervalSince1970: 9800)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "info"), now: start)
        queue.setExpanded(true, now: start.addingTimeInterval(4))

        queue.advance(now: start.addingTimeInterval(12))
        #expect(queue.active?.title == "info")
        #expect(queue.unreadCount == 0)

        queue.setExpanded(false, now: start.addingTimeInterval(14))
        #expect(queue.activeUntil == start.addingTimeInterval(20))
        #expect(queue.frozenAccrued == 10)
        queue.advance(now: start.addingTimeInterval(19))
        #expect(queue.active?.title == "info")
        queue.advance(now: start.addingTimeInterval(20))
        #expect(queue.active == nil)
        #expect(queue.unreadCount == 1)
    }

    @Test
    func `freeze-cap death retains without reshow and collapse pumps next`() {
        let start = Date(timeIntervalSince1970: 9900)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "A"), now: start)
        queue.setExpanded(true, now: start)
        queue.enqueue(Self.event(type: .completed, title: "B"), now: start, countImmediately: true)

        queue.forceRetainFrozen()
        #expect(queue.active == nil)
        #expect(queue.retained.map(\.title) == ["A"])
        #expect(queue.unreadCount == 2)

        queue.setExpanded(false, now: start.addingTimeInterval(5))
        #expect(queue.active?.title == "B")
        queue.advance(now: start.addingTimeInterval(15))
        #expect(queue.retained.map(\.title) == ["A", "B"])
        #expect(queue.unreadCount == 2)
    }

    @Test
    func `arrivals while frozen queue and count immediately without preempting`() {
        let start = Date(timeIntervalSince1970: 9950)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "info"), now: start)
        queue.setExpanded(true, now: start.addingTimeInterval(2))
        queue.enqueue(
            Self.event(type: .waiting, title: "warning"),
            now: start.addingTimeInterval(2),
            countImmediately: true)
        queue.enqueue(
            Self.event(type: .accessRequest, title: "critical"),
            now: start.addingTimeInterval(3),
            countImmediately: true)

        #expect(queue.active?.title == "info")
        #expect(queue.pending.map(\.title) == ["critical", "warning"])
        #expect(queue.unreadCount == 2)

        queue.setExpanded(false, now: start.addingTimeInterval(4))
        #expect(queue.activeUntil == start.addingTimeInterval(12))
        queue.advance(now: start.addingTimeInterval(12))
        #expect(queue.active?.title == "critical")
        #expect(queue.unreadCount == 3)
    }

    @Test
    func `frozen time accrues across expand cycles for the same item`() {
        let start = Date(timeIntervalSince1970: 9970)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "info"), now: start)
        queue.setExpanded(true, now: start.addingTimeInterval(2))
        queue.setExpanded(false, now: start.addingTimeInterval(5))
        queue.setExpanded(true, now: start.addingTimeInterval(6))
        queue.setExpanded(false, now: start.addingTimeInterval(10))

        #expect(queue.frozenAccrued == 7)
        #expect(queue.activeUntil == start.addingTimeInterval(17))
    }

    @Test
    func `pending marker tracks unresolved waiting items in active and pending`() {
        let start = Date(timeIntervalSince1970: 9980)
        var queue = NotchNotificationQueue()
        #expect(queue.pendingMarker == nil)

        queue.enqueue(Self.event(type: .completed, title: "done"), now: start)
        #expect(queue.pendingMarker == nil)

        queue.enqueue(Self.event(type: .waiting, title: "hold"), now: start)
        #expect(queue.pendingMarker == .warning)

        // Aged-out items clear the marker: retained history never nags.
        queue.advance(now: start.addingTimeInterval(10))
        queue.advance(now: start.addingTimeInterval(20))
        #expect(queue.pendingMarker == nil)
    }

    @Test
    func `pending marker prefers the critical lane`() {
        let start = Date(timeIntervalSince1970: 9990)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .waiting, title: "hold"), now: start)
        queue.enqueue(Self.event(type: .accessRequest, title: "approve"), now: start)
        #expect(queue.pendingMarker == .critical)

        queue.advance(now: start.addingTimeInterval(15))
        #expect(queue.pendingMarker == .warning)
    }

    private static func event(
        provider: String = "Codex",
        type: NotchAgentEventType,
        title: String)
        -> NotchCodingAgentNotification
    {
        NotchCodingAgentNotification(provider: provider, type: type, title: title, message: "")
    }
}
