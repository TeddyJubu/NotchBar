import AppKit
import Testing
@testable import CodexBar

private actor TestNotchSleeper: NotchSleeper {
    var requested: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        self.requested.append(duration)
    }
}

struct NotchAnimationTests {
    @Test
    func `animation tokens return nil under Reduce Motion`() {
        #expect(NotchAnimation.open(reduceMotion: true) == nil)
        #expect(NotchAnimation.close(reduceMotion: true) == nil)
        #expect(NotchAnimation.content(reduceMotion: true) == nil)
        #expect(NotchAnimation.swapInsertionAnimation(reduceMotion: true) == nil)
        #expect(NotchAnimation.swapRemovalAnimation(reduceMotion: true) == nil)
        #expect(NotchAnimation.consecutiveSwapAnimation(reduceMotion: true) == nil)
        #expect(NotchAnimation.tabAnimation(reduceMotion: true) == nil)
    }

    @Test
    func `animation tokens resolve under full motion`() {
        #expect(NotchAnimation.open(reduceMotion: false) != nil)
        #expect(NotchAnimation.close(reduceMotion: false) != nil)
        #expect(NotchAnimation.content(reduceMotion: false) != nil)
        #expect(NotchAnimation.swapInsertionAnimation(reduceMotion: false) != nil)
        #expect(NotchAnimation.swapRemovalAnimation(reduceMotion: false) != nil)
        #expect(NotchAnimation.consecutiveSwapAnimation(reduceMotion: false) != nil)
        #expect(NotchAnimation.tabAnimation(reduceMotion: false) != nil)
    }

    @Test
    func `transition tokens collapse to identity under Reduce Motion`() {
        #expect(NotchAnimation.swapInsertion(reduceMotion: true) == .identity)
        #expect(NotchAnimation.swapRemoval(reduceMotion: true) == .identity)
        #expect(NotchAnimation.consecutiveSwap(reduceMotion: true) == .identity)
        #expect(NotchAnimation.tab(forward: true, reduceMotion: true) == .identity)
        #expect(NotchAnimation.tab(forward: false, reduceMotion: true) == .identity)
    }

    @Test
    func `transition tokens resolve per site under full motion`() {
        #expect(NotchAnimation.swapInsertion(reduceMotion: false) == .swapInsertion)
        #expect(NotchAnimation.swapRemoval(reduceMotion: false) == .swapRemoval)
        #expect(NotchAnimation.consecutiveSwap(reduceMotion: false) == .consecutiveSwap)
        #expect(NotchAnimation.tab(forward: true, reduceMotion: false) == .tabForward)
        #expect(NotchAnimation.tab(forward: false, reduceMotion: false) == .tabBackward)
    }

    @Test
    func `close duration is a settle allowance above the spring response`() {
        #expect(NotchAnimation.closeDuration > 0.45)
    }

    @Test
    @MainActor
    func `panel state publishes updated view inputs together`() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32,
            leftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            rightArea: CGRect(x: 856, y: 950, width: 656, height: 32)))
        let state = NotchPanelState(
            presentation: NotchUsagePresentation(providers: [], selectedID: nil),
            geometry: geometry,
            expanded: false,
            notifications: NotchNotificationQueue(),
            showingNotifications: false)
        #expect(state.presentation.providers.isEmpty)
        #expect(state.presentation.selectedID == nil)
        #expect(state.geometry.notchWidth == geometry.notchWidth)
        #expect(state.expanded == false)
        #expect(state.notifications == NotchNotificationQueue())
        #expect(state.showingNotifications == false)

        var notifications = NotchNotificationQueue()
        notifications.enqueue(
            NotchCodingAgentNotification(provider: "Codex", title: "Task finished", message: "Done"),
            now: Date())
        let providers = [NotchUsageProvider(id: "codex", name: "Codex", windows: [], updatedAt: nil, error: nil)]
        state.update(
            presentation: NotchUsagePresentation(providers: providers, selectedID: "codex"),
            geometry: geometry,
            expanded: true,
            notifications: notifications,
            showingNotifications: true)
        #expect(state.presentation.selected?.id == "codex")
        #expect(state.geometry.notchWidth == geometry.notchWidth)
        #expect(state.expanded == true)
        #expect(state.notifications == notifications)
        #expect(state.showingNotifications == true)
    }

    @Test
    func `sleeper double records requested durations without sleeping`() async throws {
        let sleeper = TestNotchSleeper()
        try await sleeper.sleep(.seconds(1))
        try await sleeper.sleep(.milliseconds(250))
        let requested = await sleeper.requested
        #expect(requested == [.seconds(1), .milliseconds(250)])
    }

    @Test
    func `live sleeper completes a zero sleep`() async throws {
        try await LiveNotchSleeper().sleep(.zero)
    }

    @Test
    func `swap transition is asymmetric under full motion and identity under Reduce Motion`() {
        #expect(NotchAnimation.swapTransition(reduceMotion: false) == .swap)
        #expect(NotchAnimation.swapTransition(reduceMotion: true) == .identity)
    }

    @Test
    func `hairline fraction runs 1 to 0 across the window and clamps`() {
        let since = Date(timeIntervalSince1970: 1000)
        let until = Date(timeIntervalSince1970: 1010)
        #expect(NotchAnimation.hairlineFraction(now: since, since: since, until: until) == 1)
        #expect(NotchAnimation.hairlineFraction(now: until, since: since, until: until) == 0)
        #expect(NotchAnimation.hairlineFraction(
            now: Date(timeIntervalSince1970: 1005), since: since, until: until) == 0.5)
        #expect(NotchAnimation.hairlineFraction(
            now: Date(timeIntervalSince1970: 999), since: since, until: until) == 1)
        #expect(NotchAnimation.hairlineFraction(
            now: Date(timeIntervalSince1970: 1011), since: since, until: until) == 0)
        #expect(NotchAnimation.hairlineFraction(now: since, since: since, until: since) == 0)
    }

    @Test
    func `badge id changes with the unread count`() {
        #expect(NotchAnimation.badgeID(1) == "unread-1")
        #expect(NotchAnimation.badgeID(2) == "unread-2")
        #expect(NotchAnimation.badgeID(1) != NotchAnimation.badgeID(2))
    }

    @Test
    func `marquee scrolls only on overflow with motion allowed`() {
        #expect(NotchAnimation.marqueeScrolls(textWidth: 200, frameWidth: 100, reduceMotion: false))
        #expect(!NotchAnimation.marqueeScrolls(textWidth: 100, frameWidth: 100, reduceMotion: false))
        #expect(!NotchAnimation.marqueeScrolls(textWidth: 50, frameWidth: 100, reduceMotion: false))
        #expect(!NotchAnimation.marqueeScrolls(textWidth: 0, frameWidth: 100, reduceMotion: false))
        #expect(!NotchAnimation.marqueeScrolls(textWidth: 200, frameWidth: 0, reduceMotion: false))
        #expect(!NotchAnimation.marqueeScrolls(textWidth: 200, frameWidth: 100, reduceMotion: true))
    }

    @Test
    func `count suffix is blank for singletons`() {
        #expect(NotchAnimation.countSuffix(0).isEmpty)
        #expect(NotchAnimation.countSuffix(1).isEmpty)
        #expect(NotchAnimation.countSuffix(2) == " ×2")
        #expect(NotchAnimation.countSuffix(12) == " ×12")
    }

    @Test
    func `collapse completes only for the live generation on a collapsed running panel`() {
        #expect(NotchAnimation.shouldCompleteCollapse(
            firedGeneration: 3, currentGeneration: 3, running: true, expanded: false))
        #expect(!NotchAnimation.shouldCompleteCollapse(
            firedGeneration: 2, currentGeneration: 3, running: true, expanded: false))
        #expect(!NotchAnimation.shouldCompleteCollapse(
            firedGeneration: 3, currentGeneration: 3, running: true, expanded: true))
        #expect(!NotchAnimation.shouldCompleteCollapse(
            firedGeneration: 3, currentGeneration: 3, running: false, expanded: false))
    }
}
