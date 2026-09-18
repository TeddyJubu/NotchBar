import Foundation
import Testing
@testable import CodexBar

struct NotchExpandingNoticeTests {
    @Test(arguments: [
        (NotchAgentEventType.completed, NotchNoticeTier.sneakPeek),
        (NotchAgentEventType.waiting, NotchNoticeTier.sneakPeek),
        (NotchAgentEventType.failed, NotchNoticeTier.sneakPeek),
        (NotchAgentEventType.accessRequest, NotchNoticeTier.expanding),
    ])
    func `agent types derive their presentation tier`(type: NotchAgentEventType, tier: NotchNoticeTier) {
        #expect(type.noticeTier == tier)
        let notification = NotchCodingAgentNotification(provider: "Codex", type: type, title: "t", message: "")
        #expect(notification.noticeTier == tier)
        #expect(notification.showsExpanded == (tier == .expanding))
    }

    @Test(arguments: [
        (NotchAgentEventType.completed, "checkmark.circle", "Done"),
        (NotchAgentEventType.waiting, "ellipsis.circle", "Waiting"),
        (NotchAgentEventType.failed, "exclamationmark.triangle", "Failed"),
        (NotchAgentEventType.accessRequest, "questionmark.circle", "Needs approval"),
    ])
    func `severity presentation follows the routing table`(
        type: NotchAgentEventType,
        symbol: String,
        label: String)
    {
        #expect(type.symbolName == symbol)
        #expect(type.severityLabel == label)
    }

    @Test(arguments: [
        (true, true, true, true),
        (true, true, true, false),
        (true, true, false, true),
        (true, false, true, true),
        (false, true, true, true),
        (false, false, false, false),
    ])
    func `dwell clears only when live expanded on frontmost alerts`(
        live: Bool,
        expanded: Bool,
        showing: Bool,
        front: Bool)
    {
        #expect(NotchAnimation.shouldClearUnreadOnDwell(
            firedGeneration: live ? 3 : 2,
            currentGeneration: 3,
            expanded: expanded,
            showingNotifications: showing,
            panelFront: front) == (live && expanded && showing && front))
    }

    @Test
    func `superseded dwell never clears the badge`() {
        // Tab leave and collapse bump the generation, so a stale fire is dead
        // even when the panel later returns to frontmost ALERTS.
        #expect(!NotchAnimation.shouldClearUnreadOnDwell(
            firedGeneration: 1,
            currentGeneration: 2,
            expanded: true,
            showingNotifications: true,
            panelFront: true))
    }

    @Test
    func `dismiss retains and shows the next item immediately`() {
        let start = Date(timeIntervalSince1970: 11000)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .accessRequest, title: "critical"), now: start)
        queue.enqueue(Self.event(type: .completed, title: "info"), now: start)
        #expect(queue.active?.title == "critical")

        queue.dismissActive(now: start.addingTimeInterval(2))
        #expect(queue.retained.map(\.title) == ["critical"])
        #expect(queue.unreadCount == 1)
        #expect(queue.active?.title == "info")
        #expect(queue.activeUntil == start.addingTimeInterval(12))

        // The dismissed item is dead: no reshow, no second count.
        queue.advance(now: start.addingTimeInterval(12))
        #expect(queue.active == nil)
        #expect(queue.retained.map(\.title) == ["critical", "info"])
        #expect(queue.unreadCount == 2)
    }

    @Test
    func `dismiss of the last item resets the fairness counter`() {
        let start = Date(timeIntervalSince1970: 11100)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .accessRequest, title: "only"), now: start)
        #expect(queue.consecutiveCriticalShows == 1)

        queue.dismissActive(now: start.addingTimeInterval(1))
        #expect(queue.active == nil)
        #expect(queue.consecutiveCriticalShows == 0)
        #expect(queue.unreadCount == 1)
    }

    @Test
    func `dismiss with nothing active is a no-op`() {
        var queue = NotchNotificationQueue()
        queue.dismissActive(now: Date())
        #expect(queue == NotchNotificationQueue())
    }

    @Test
    func `dismiss while frozen promotes under the freeze`() {
        let start = Date(timeIntervalSince1970: 11200)
        var queue = NotchNotificationQueue()
        queue.enqueue(Self.event(type: .completed, title: "info"), now: start)
        queue.setExpanded(true, now: start.addingTimeInterval(2))
        queue.enqueue(
            Self.event(type: .completed, title: "queued"),
            now: start.addingTimeInterval(2),
            countImmediately: true)

        queue.dismissActive(now: start.addingTimeInterval(3))
        #expect(queue.retained.map(\.title) == ["info"])
        #expect(queue.active?.title == "queued")
        #expect(queue.isFrozen)
        #expect(queue.unreadCount == 2)

        // The promoted item stays frozen until collapse extends its window.
        queue.advance(now: start.addingTimeInterval(20))
        #expect(queue.active?.title == "queued")
        queue.setExpanded(false, now: start.addingTimeInterval(5))
        queue.advance(now: Date(timeIntervalSince1970: 11200 + 3 + 10 + 3))
        #expect(queue.active == nil)
        #expect(queue.unreadCount == 2)
    }

    @Test
    func `expanding frame adds the takeover height instead of one row`() throws {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let geometry = try #require(NotchGeometry(
            screenFrame: screen,
            safeAreaTop: 32,
            leftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            rightArea: CGRect(x: 856, y: 950, width: 656, height: 32)))
        #expect(geometry.frame(expanded: false, expandingNoticeVisible: true).height
            == geometry.expandingNoticeCompactSize.height)
        #expect(geometry.frame(expanded: true, expandingNoticeVisible: true).height
            == geometry.expandingNoticeExpandedSize.height)
        #expect(geometry.expandingNoticeCompactSize.height
            == geometry.compactSize.height + NotchGeometry.expandingNoticeHeight)
        #expect(geometry.expandingNoticeCompactSize.height > geometry.notificationCompactSize.height)
        let frame = geometry.frame(expanded: false, expandingNoticeVisible: true)
        #expect(frame.maxY == screen.maxY)
        #expect(screen.contains(frame))
    }

    private static func event(type: NotchAgentEventType, title: String) -> NotchCodingAgentNotification {
        NotchCodingAgentNotification(provider: "Codex", type: type, title: title, message: "")
    }
}
