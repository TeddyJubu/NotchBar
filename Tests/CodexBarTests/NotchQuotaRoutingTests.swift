import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NotchQuotaRoutingTests {
    private final class NoticeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var notices: [NotchCodingAgentNotification] = []

        func append(_ notice: NotchCodingAgentNotification) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.notices.append(notice)
        }

        func get() -> [NotchCodingAgentNotification] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.notices
        }
    }

    private static func observingNotices() -> (NoticeRecorder, NSObjectProtocol) {
        let recorder = NoticeRecorder()
        let token = NotificationCenter.default.addObserver(
            forName: .codexBarCodingAgentNotification,
            object: nil,
            queue: nil)
        { notification in
            guard let notice = notification.object as? NotchCodingAgentNotification else { return }
            recorder.append(notice)
        }
        return (recorder, token)
    }

    @Test(arguments: [
        (
            NotchAgentEventType.quotaDepleted, NotchNotificationSeverity.critical, NotchNoticeTier.expanding,
            "exclamationmark.octagon", "Limit reached"),
        (
            NotchAgentEventType.quotaWarning, NotchNotificationSeverity.warning, NotchNoticeTier.sneakPeek,
            "gauge.with.dots.needle.50percent", "Running low"),
        (
            NotchAgentEventType.predictiveWarning, NotchNotificationSeverity.warning, NotchNoticeTier.sneakPeek,
            "gauge.with.dots.needle.50percent", "Running low"),
        (
            NotchAgentEventType.quotaRestored, NotchNotificationSeverity.info, NotchNoticeTier.sneakPeek,
            "checkmark.circle", "Restored"),
        (
            NotchAgentEventType.creditExpiry, NotchNotificationSeverity.warning, NotchNoticeTier.sneakPeek,
            "hourglass", "Expiring"),
    ])
    func `quota types route per the severity table`(
        type: NotchAgentEventType,
        lane: NotchNotificationSeverity,
        tier: NotchNoticeTier,
        symbol: String,
        label: String)
    {
        #expect(type.severity == lane)
        #expect(type.noticeTier == tier)
        #expect(type.symbolName == symbol)
        #expect(type.severityLabel == label)
    }

    @Test(arguments: [
        NotchAgentEventType.quotaDepleted,
        NotchAgentEventType.quotaWarning,
        NotchAgentEventType.quotaRestored,
        NotchAgentEventType.creditExpiry,
        NotchAgentEventType.predictiveWarning,
    ])
    @MainActor
    func `quota types are producer-built, never hook-parsed`(type: NotchAgentEventType) {
        #expect(!type.isHookType)
        let line = Data(#"{"source":"codex","type":"\#(type.rawValue)","title":"t","message":"m"}"#.utf8)
        #expect(NotchAgentEventSource.notification(from: line, now: Date()) == nil)
    }

    @Test
    func `depleted transition builds a critical T2 notice with banner copy`() {
        let notice = NotchCodingAgentNotification(quotaTransition: .depleted, providerName: "Codex")
        let copy = SessionQuotaNotificationLogic.notificationCopy(transition: .depleted, providerName: "Codex")
        #expect(notice.type == .quotaDepleted)
        #expect(notice.severity == .critical)
        #expect(notice.showsExpanded)
        #expect(notice.tierBase == NotchNotificationQueue.expandedDisplayDuration)
        #expect(notice.provider == "Codex")
        #expect(notice.title == copy.title)
        #expect(notice.message == copy.body)
    }

    @Test
    func `restored transition builds an info T1 notice with banner copy`() {
        let notice = NotchCodingAgentNotification(quotaTransition: .restored, providerName: "Codex")
        let copy = SessionQuotaNotificationLogic.notificationCopy(transition: .restored, providerName: "Codex")
        #expect(notice.type == .quotaRestored)
        #expect(notice.severity == .info)
        #expect(!notice.showsExpanded)
        #expect(notice.title == copy.title)
        #expect(notice.message == copy.body)
    }

    @Test
    func `threshold warning builds a warning T1 notice with banner copy`() {
        let event = QuotaWarningEvent(window: .session, threshold: 20, currentRemaining: 15)
        let notice = NotchCodingAgentNotification(quotaWarning: event, providerName: "Codex")
        let copy = QuotaWarningNotificationLogic.notificationCopy(
            providerName: "Codex",
            window: .session,
            threshold: 20,
            currentRemaining: 15)
        #expect(notice.type == .quotaWarning)
        #expect(notice.severity == .warning)
        #expect(!notice.showsExpanded)
        #expect(notice.title == copy.title)
        #expect(notice.message == copy.body)
    }

    @Test
    func `predictive warning builds a warning T1 notice with banner copy`() {
        let now = Date(timeIntervalSince1970: 9000)
        let event = PredictivePaceWarningEvent(window: .session, etaSeconds: 3600, accountDisplayName: nil)
        let notice = NotchCodingAgentNotification(predictivePaceWarning: event, providerName: "Codex", now: now)
        let copy = PredictivePaceWarningNotificationLogic.notificationCopy(
            providerName: "Codex",
            event: event,
            now: now)
        #expect(notice.type == .predictiveWarning)
        #expect(notice.severity == .warning)
        #expect(!notice.showsExpanded)
        #expect(notice.title == copy.title)
        #expect(notice.message == copy.body)
    }

    @Test
    func `credit expiry builds a warning T1 notice`() {
        let notice = NotchCodingAgentNotification(
            creditExpiryTitle: "Limit Reset Credits",
            body: "1. Expires in 1d",
            providerName: "Codex")
        #expect(notice.type == .creditExpiry)
        #expect(notice.severity == .warning)
        #expect(!notice.showsExpanded)
        #expect(notice.title == "Limit Reset Credits")
        #expect(notice.message == "1. Expires in 1d")
    }

    @Test
    @MainActor
    func `routing posts through the existing path to controller receive`() {
        let (recorder, token) = Self.observingNotices()
        defer { NotificationCenter.default.removeObserver(token) }
        let notice = NotchCodingAgentNotification(quotaTransition: .depleted, providerName: "Codex")

        NotchQuotaNoticeRouting.post(notice)

        #expect(recorder.get().map(\.id) == [notice.id])
    }

    @Test
    @MainActor
    func `session quota posts route depleted and restored to the notch`() {
        let (recorder, token) = Self.observingNotices()
        defer { NotificationCenter.default.removeObserver(token) }
        let notifier = SessionQuotaNotifier()

        notifier.post(transition: .depleted, provider: .codex)
        notifier.post(transition: .restored, provider: .codex)
        notifier.post(transition: .none, provider: .codex)

        #expect(recorder.get().map(\.type) == [.quotaDepleted, .quotaRestored])
    }

    @Test
    @MainActor
    func `threshold warning post routes to the notch`() {
        let (recorder, token) = Self.observingNotices()
        defer { NotificationCenter.default.removeObserver(token) }

        SessionQuotaNotifier().postQuotaWarning(
            event: QuotaWarningEvent(window: .session, threshold: 20, currentRemaining: 15),
            provider: .codex,
            soundEnabled: false,
            onScreenAlertEnabled: false)

        let notices = recorder.get()
        #expect(notices.count == 1)
        #expect(notices.first?.type == .quotaWarning)
    }

    @Test
    @MainActor
    func `predictive pace post routes to the notch`() {
        let (recorder, token) = Self.observingNotices()
        defer { NotificationCenter.default.removeObserver(token) }

        SessionQuotaNotifier().postPredictivePaceWarning(
            event: PredictivePaceWarningEvent(window: .session, etaSeconds: 3600, accountDisplayName: nil),
            provider: .codex,
            soundEnabled: false,
            onScreenAlertEnabled: false,
            now: Date(timeIntervalSince1970: 9000))

        let notices = recorder.get()
        #expect(notices.count == 1)
        #expect(notices.first?.type == .predictiveWarning)
    }

    @Test
    @MainActor
    func `credit expiry post routes to the notch`() throws {
        let suite = "NotchQuotaRoutingTests-credit-expiry-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (recorder, token) = Self.observingNotices()
        defer { NotificationCenter.default.removeObserver(token) }
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let notifier = CodexResetCreditExpiryNotifier(userDefaults: defaults) { _, _, _ in }

        notifier.postExpiringCreditsIfNeeded(
            snapshot: CodexRateLimitResetCreditsSnapshot(
                credits: [Self.credit(expiresAt: now.addingTimeInterval(86400))],
                availableCount: 1,
                updatedAt: now),
            resetStyle: .countdown,
            now: now)

        let notices = recorder.get()
        #expect(notices.count == 1)
        #expect(notices.first?.type == .creditExpiry)
    }

    @Test(arguments: [
        (true, true, false, true),
        (false, true, false, false),
        (true, false, false, false),
        (true, true, true, false),
        (false, false, true, false),
    ])
    func `OS post suppresses only when T1 or T2 will show`(
        notchEnabled: Bool,
        geometryAvailable: Bool,
        screenLocked: Bool,
        showsNotchNotice: Bool)
    {
        let policy = NotchNoticeChannelPolicy(
            notchEnabled: notchEnabled,
            geometryAvailable: geometryAvailable,
            screenLocked: screenLocked)
        #expect(policy.showsNotchNotice == showsNotchNotice)
    }

    @Test
    @MainActor
    func `unrouted posts always keep the OS fallback`() {
        let showing = NotchNoticeChannelPolicy(notchEnabled: true, geometryAvailable: true, screenLocked: false)
        let center = AppNotifications(channelPolicyProvider: { showing })
        #expect(center.shouldSuppressOSPost(notchRouted: false) == false)
    }

    @Test
    @MainActor
    func `routed posts suppress only when the notch will show`() {
        let showing = NotchNoticeChannelPolicy(notchEnabled: true, geometryAvailable: true, screenLocked: false)
        let locked = NotchNoticeChannelPolicy(notchEnabled: true, geometryAvailable: true, screenLocked: true)
        #expect(AppNotifications(channelPolicyProvider: { showing }).shouldSuppressOSPost(notchRouted: true))
        #expect(!AppNotifications(channelPolicyProvider: { locked }).shouldSuppressOSPost(notchRouted: true))
    }

    @Test
    @MainActor
    func `screen lock monitor tracks the distributed lock names`() {
        #expect(ScreenLockMonitor.lockedName.rawValue == "com.apple.screenIsLocked")
        #expect(ScreenLockMonitor.unlockedName.rawValue == "com.apple.screenIsUnlocked")
        let monitor = ScreenLockMonitor()
        #expect(!monitor.isLocked)
        monitor.handleLockChange(locked: true)
        #expect(monitor.isLocked)
        monitor.handleLockChange(locked: false)
        #expect(!monitor.isLocked)
    }

    @Test
    func `quota notices never raise the agent pending marker`() {
        let start = Date(timeIntervalSince1970: 8100)
        var queue = NotchNotificationQueue()
        queue.enqueue(
            NotchCodingAgentNotification(quotaTransition: .depleted, providerName: "Codex"),
            now: start)
        #expect(queue.pendingMarker == nil)
    }

    private static func credit(expiresAt: Date?) -> CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(
            id: UUID().uuidString,
            resetType: "codex_rate_limits",
            status: .available,
            grantedAt: Date(timeIntervalSince1970: 1_781_700_000),
            expiresAt: expiresAt,
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)
    }
}
