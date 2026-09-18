import Foundation
import Testing
@testable import CodexBar

struct NotchSeverityTests {
    @Test(arguments: [
        (NotchAgentEventType.completed, NotchNotificationSeverity.info),
        (NotchAgentEventType.waiting, NotchNotificationSeverity.warning),
        (NotchAgentEventType.failed, NotchNotificationSeverity.warning),
        (NotchAgentEventType.accessRequest, NotchNotificationSeverity.critical),
    ])
    func `hook types route to their severity lane`(type: NotchAgentEventType, lane: NotchNotificationSeverity) {
        #expect(type.severity == lane)
    }

    @Test
    func `severity lanes order info below warning below critical`() {
        #expect(NotchNotificationSeverity.info < NotchNotificationSeverity.warning)
        #expect(NotchNotificationSeverity.warning < NotchNotificationSeverity.critical)
        #expect(!(NotchNotificationSeverity.critical < NotchNotificationSeverity.info))
    }

    @Test(arguments: [
        ("completed", NotchAgentEventType.completed),
        ("failed", NotchAgentEventType.failed),
        ("waiting", NotchAgentEventType.waiting),
        ("access_request", NotchAgentEventType.accessRequest),
    ])
    @MainActor
    func `parser preserves the hook type`(rawType: String, type: NotchAgentEventType) throws {
        let now = Date(timeIntervalSince1970: 7000)
        let line = Data(
            #"{"source":"codex","type":"\#(rawType)","title":"t","message":"m"}"#.utf8)
        let event = try #require(NotchAgentEventSource.notification(from: line, now: now))
        #expect(event.type == type)
        #expect(event.severity == type.severity)
    }

    @Test
    func `pending stays lane-ordered with FIFO within each lane`() {
        // Warnings and infos never preempt, so lane order is directly observable.
        let start = Date(timeIntervalSince1970: 8000)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "active-info"), now: start)
        queue.enqueue(Self.event(type: .completed, title: "info-1"), now: start)
        queue.enqueue(Self.event(type: .waiting, title: "warning-1"), now: start)
        queue.enqueue(Self.event(type: .failed, title: "warning-2"), now: start)
        queue.enqueue(Self.event(type: .completed, title: "info-2"), now: start)

        #expect(queue.active?.title == "active-info")
        #expect(queue.pending.map(\.title) == ["warning-1", "warning-2", "info-1", "info-2"])
    }

    @Test
    func `critical arrival preempts the active window and preserves its remainder`() {
        let start = Date(timeIntervalSince1970: 8050)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "active-info"), now: start)
        queue.enqueue(Self.event(type: .accessRequest, title: "critical"), now: start.addingTimeInterval(3))

        #expect(queue.active?.title == "critical")
        #expect(queue.activeUntil == start.addingTimeInterval(18))
        #expect(queue.consecutiveCriticalShows == 1)
        #expect(queue.pending.map(\.title) == ["active-info"])

        // The preempted info resumes with its 7s remainder once the critical expires.
        queue.advance(now: start.addingTimeInterval(18))
        #expect(queue.active?.title == "active-info")
        #expect(queue.activeUntil == start.addingTimeInterval(25))
        #expect(queue.retained.map(\.title) == ["critical"])
        #expect(queue.unreadCount == 1)

        queue.advance(now: start.addingTimeInterval(25))
        #expect(queue.retained.map(\.title) == ["critical", "active-info"])
        #expect(queue.unreadCount == 2)
        #expect(queue.active == nil)
    }

    @Test
    func `advance selects lanes critical first then warning then info`() {
        // Arrivals while frozen always queue, so the lane order is observable
        // without preemption; collapse pumps the lane head.
        let start = Date(timeIntervalSince1970: 8100)
        var queue = NotchNotificationQueue()
        queue.setExpanded(true, now: start)
        queue.enqueue(Self.event(type: .completed, title: "info"), now: start)
        queue.enqueue(Self.event(type: .failed, title: "warning"), now: start)
        queue.enqueue(Self.event(type: .accessRequest, title: "critical"), now: start)
        #expect(queue.active == nil)
        #expect(queue.pending.map(\.title) == ["critical", "warning", "info"])

        queue.setExpanded(false, now: start)
        #expect(queue.active?.title == "critical")
        #expect(queue.activeUntil == start.addingTimeInterval(15))
        queue.advance(now: start.addingTimeInterval(15))
        #expect(queue.active?.title == "warning")
        queue.advance(now: start.addingTimeInterval(25))
        #expect(queue.active?.title == "info")
        queue.advance(now: start.addingTimeInterval(35))
        #expect(queue.active == nil)
        #expect(queue.retained.map(\.title) == ["critical", "warning", "info"])
        #expect(queue.unreadCount == 3)
    }

    @Test
    func `preempted info resumes with its remainder and counts once`() {
        let start = Date(timeIntervalSince1970: 8200)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "active-info"), now: start)
        queue.enqueue(Self.event(type: .accessRequest, title: "critical"), now: start.addingTimeInterval(4))

        #expect(queue.active?.title == "critical")
        queue.advance(now: start.addingTimeInterval(19))
        #expect(queue.active?.title == "active-info")
        #expect(queue.activeUntil == start.addingTimeInterval(25))
        #expect(queue.retained.map(\.title) == ["critical"])
        #expect(queue.unreadCount == 1)

        queue.advance(now: start.addingTimeInterval(25))
        #expect(queue.retained.map(\.title) == ["critical", "active-info"])
        #expect(queue.unreadCount == 2)
        #expect(queue.consecutiveCriticalShows == 0)
    }

    @Test
    func `pending cap keeps the highest-severity items`() {
        let start = Date(timeIntervalSince1970: 8300)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "active"), now: start)
        for index in 0..<NotchNotificationQueue.maxPendingCount {
            queue.enqueue(Self.event(type: .completed, title: "info-\(index)"), now: start)
        }
        // The critical preempts; the preempted active lands at the tail of a
        // full same-severity lane and is evicted, counting once on eviction.
        queue.enqueue(Self.event(type: .accessRequest, title: "critical"), now: start)

        #expect(queue.active?.title == "critical")
        #expect(queue.pending.count == NotchNotificationQueue.maxPendingCount)
        #expect(queue.pending.map(\.title) == (0..<NotchNotificationQueue.maxPendingCount).map { "info-\($0)" })
        #expect(queue.unreadCount == 1)
    }

    @Test
    func `retained and unread caps behave as before under lane ordering`() {
        let start = Date(timeIntervalSince1970: 8400)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .accessRequest, title: "active"), now: start)
        for index in 0..<(NotchNotificationQueue.maxPendingCount + 5) {
            let type: NotchAgentEventType = index.isMultiple(of: 2) ? .failed : .completed
            queue.enqueue(Self.event(type: type, title: "alert-\(index)"), now: start)
        }
        #expect(queue.pending.count == NotchNotificationQueue.maxPendingCount)

        for index in 0..<(NotchNotificationQueue.maxPendingCount + 5) {
            queue.advance(now: start.addingTimeInterval(Double(index + 1) * NotchNotificationQueue.displayDuration))
        }
        #expect(queue.retained.count <= NotchNotificationQueue.maxRetainedCount)
        #expect(queue.unreadCount <= NotchNotificationQueue.maxRetainedCount)
        queue.markUnreadRead()
        #expect(queue.unreadCount == 0)
        #expect(queue.retained.count <= NotchNotificationQueue.maxRetainedCount)
    }

    private static func event(type: NotchAgentEventType, title: String) -> NotchCodingAgentNotification {
        NotchCodingAgentNotification(provider: "Codex", type: type, title: title, message: "")
    }
}
