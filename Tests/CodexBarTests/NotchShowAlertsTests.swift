import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct NotchShowAlertsTests {
    @Test
    func `tab index maps usage to zero and alerts to one`() {
        #expect(NotchAnimation.tabIndex(showingNotifications: false) == 0)
        #expect(NotchAnimation.tabIndex(showingNotifications: true) == 1)
    }

    @Test(arguments: [
        (false, true, true),
        (true, false, false),
        (false, false, false),
        (true, true, false),
    ])
    func `tab direction derives from the index delta`(from: Bool, to: Bool, forward: Bool) {
        #expect(NotchAnimation.tabForward(from: from, to: to) == forward)
    }

    @Test
    func `panel state tracks the tab direction across updates`() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32,
            leftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            rightArea: CGRect(x: 856, y: 950, width: 656, height: 32)))
        let state = NotchPanelState(
            presentation: NotchUsagePresentation(providers: [], selectedID: nil),
            geometry: geometry,
            expanded: true,
            notifications: NotchNotificationQueue(),
            showingNotifications: false)
        let update = { showing in
            state.update(
                presentation: state.presentation,
                geometry: geometry,
                expanded: true,
                notifications: state.notifications,
                showingNotifications: showing)
        }

        update(true)
        #expect(state.tabForward)
        update(true)
        #expect(state.tabForward)
        update(false)
        #expect(!state.tabForward)
    }

    @Test
    func `announcement throttle passes the leading edge then one per five seconds`() {
        let start = Date(timeIntervalSince1970: 20000)
        #expect(NotchAnimation.shouldAnnounce(now: start, lastAnnouncement: nil))
        #expect(!NotchAnimation.shouldAnnounce(now: start.addingTimeInterval(4.99), lastAnnouncement: start))
        #expect(NotchAnimation.shouldAnnounce(now: start.addingTimeInterval(5), lastAnnouncement: start))
        #expect(NotchAnimation.shouldAnnounce(now: start.addingTimeInterval(9), lastAnnouncement: start))
    }

    @Test
    func `announcement text names severity title count and message`() {
        let notice = NotchCodingAgentNotification(
            provider: "Claude Code",
            type: .accessRequest,
            count: 3,
            title: "Needs approval",
            message: "Waiting on you")
        #expect(notice.announcementText == "Claude Code: Needs approval: Needs approval ×3: Waiting on you")

        let quiet = NotchCodingAgentNotification(provider: "Codex", title: "Task finished", message: "")
        #expect(quiet.announcementText == "Codex: Done: Task finished")
    }

    @Test(arguments: [
        ("d", false, true),
        ("D", false, true),
        ("d", true, false),
        ("D", true, false),
        ("x", false, false),
        (nil, false, false),
    ])
    func `d without modifiers dismisses the notice`(
        characters: String?,
        hasModifiers: Bool,
        dismisses: Bool)
    {
        #expect(NotchAnimation.isNoticeDismissKeyPress(
            charactersIgnoringModifiers: characters,
            hasModifiers: hasModifiers) == dismisses)
    }

    @Test
    func `notch section carries the show alerts action`() {
        let entries = MenuDescriptor.notchSection().entries
        #expect(entries.count == 2)
        guard entries.count == 2 else { return }
        guard case let .text(headline, style) = entries[0] else {
            Issue.record("Notch section must open with a headline")
            return
        }
        #expect(headline == "Notch")
        #expect(style == .headline)
        guard case let .action(title, action) = entries[1] else {
            Issue.record("Notch section must carry the Show Alerts action")
            return
        }
        #expect(title == "Show Alerts")
        #expect(action == .showNotchAlerts)
    }

    @Test
    func `menu includes the notch section only when requested`() {
        let settings = testSettingsStore(suiteName: "NotchShowAlertsTests-notch-section")
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let build = { includeNotchSection in
            MenuDescriptor.build(
                provider: .codex,
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updateReady: false,
                includeNotchSection: includeNotchSection)
        }

        #expect(!build(false).sections.flatMap(\.entries).contains { $0.isShowNotchAlerts })
        #expect(!MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false).sections.flatMap(\.entries).contains { $0.isShowNotchAlerts })

        let included = build(true).sections.flatMap(\.entries)
        #expect(included.contains { $0.isShowNotchAlerts })
    }

    @Test
    func `notch section defaults on and respects the disable flag`() throws {
        let suiteName = "NotchShowAlertsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MenuDescriptor.notchSectionEnabled(defaults: defaults))
        defaults.set(false, forKey: "notchUsageEnabled")
        #expect(!MenuDescriptor.notchSectionEnabled(defaults: defaults))
        defaults.set(true, forKey: "notchUsageEnabled")
        #expect(MenuDescriptor.notchSectionEnabled(defaults: defaults))
    }
}

extension MenuDescriptor.Entry {
    fileprivate var isShowNotchAlerts: Bool {
        guard case .action(_, .showNotchAlerts) = self else { return false }
        return true
    }
}
