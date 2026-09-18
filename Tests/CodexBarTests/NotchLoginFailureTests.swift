import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct NotchLoginFailureTests {
    @Test
    func `login failure routes per the severity table`() {
        let type = NotchAgentEventType.loginFailure
        #expect(type.rawValue == "login_failure")
        #expect(type.severity == .critical)
        #expect(type.noticeTier == .expanding)
        #expect(type.symbolName == "person.crop.circle.badge.xmark")
        #expect(type.severityLabel == "Sign-in failed")
    }

    @Test
    @MainActor
    func `login failure is producer-built, never hook-parsed`() {
        #expect(!NotchAgentEventType.loginFailure.isHookType)
        let line = Data(#"{"source":"codex","type":"login_failure","title":"t","message":"m"}"#.utf8)
        #expect(NotchAgentEventSource.notification(from: line, now: Date()) == nil)
    }

    @Test(arguments: [UsageProvider.codex, .claude, .cursor, .gemini, .antigravity])
    func `producer maps provider and modal copy into a critical T2 notice`(provider: UsageProvider) {
        let notice = NotchCodingAgentNotification(
            loginFailureTitle: "Claude login failed",
            body: "exited with status 1",
            provider: provider)

        #expect(notice.type == .loginFailure)
        #expect(notice.severity == .critical)
        #expect(notice.showsExpanded)
        #expect(notice.tierBase == NotchNotificationQueue.expandedDisplayDuration)
        #expect(notice.tierFloor == NotchNotificationQueue.expandedReshowFloor)
        #expect(notice.provider == ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName)
        #expect(notice.title == "Claude login failed")
        #expect(notice.message == "exited with status 1")
    }

    @Test
    func `login failure flag defaults on and reverses through defaults`() throws {
        let suite = "NotchLoginFailureTests-flag-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(NotchLoginFailureNotices.isEnabled(defaults: defaults))
        defaults.set(false, forKey: NotchLoginFailureNotices.enabledDefaultsKey)
        #expect(!NotchLoginFailureNotices.isEnabled(defaults: defaults))
        defaults.set(true, forKey: NotchLoginFailureNotices.enabledDefaultsKey)
        #expect(NotchLoginFailureNotices.isEnabled(defaults: defaults))
    }

    @Test(arguments: [
        (true, true, false, true),
        (true, true, true, false),
        (true, false, false, false),
        (true, false, true, false),
        (false, true, false, false),
        (false, true, true, false),
        (false, false, false, false),
        (false, false, true, false),
    ])
    func `fallback trigger table shows the notch notice only when it can show`(
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

    @Test(arguments: [
        (true, true, false, true),
        (true, true, true, false),
        (true, false, false, false),
        (true, false, true, false),
        (false, true, false, false),
        (false, true, true, false),
        (false, false, false, false),
        (false, false, true, false),
    ])
    @MainActor
    func `single-channel rule consumes the one predicate for routed posts`(
        notchEnabled: Bool,
        geometryAvailable: Bool,
        screenLocked: Bool,
        suppresses: Bool)
    {
        let policy = NotchNoticeChannelPolicy(
            notchEnabled: notchEnabled,
            geometryAvailable: geometryAvailable,
            screenLocked: screenLocked)
        let center = AppNotifications(channelPolicyProvider: { policy })
        #expect(center.shouldSuppressOSPost(notchRouted: true) == suppresses)
        #expect(!center.shouldSuppressOSPost(notchRouted: false))
    }

    @Test
    func `login failure never raises the agent pending marker`() {
        let start = Date(timeIntervalSince1970: 8100)
        var queue = NotchNotificationQueue()
        queue.enqueue(
            NotchCodingAgentNotification(loginFailureTitle: "t", body: "m", provider: .codex),
            now: start)
        #expect(queue.pendingMarker == nil)
    }
}
