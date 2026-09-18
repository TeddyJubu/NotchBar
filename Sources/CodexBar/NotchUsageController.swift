import AppKit
import CodexBarCore
import Observation
import SwiftUI

/// Stable state owner for the notch panel root view.
///
/// The controller creates the `NSHostingView` root once with this object and
/// mutates its properties on later renders instead of replacing `rootView`,
/// preserving view identity, `@State`, and in-flight transitions.
@MainActor @Observable
final class NotchPanelState {
    var presentation: NotchUsagePresentation
    var geometry: NotchGeometry
    var expanded: Bool
    var notifications: NotchNotificationQueue
    var showingNotifications: Bool
    var tabForward: Bool

    init(
        presentation: NotchUsagePresentation,
        geometry: NotchGeometry,
        expanded: Bool,
        notifications: NotchNotificationQueue,
        showingNotifications: Bool,
        tabForward: Bool = true)
    {
        self.presentation = presentation
        self.geometry = geometry
        self.expanded = expanded
        self.notifications = notifications
        self.showingNotifications = showingNotifications
        self.tabForward = tabForward
    }

    func update(
        presentation: NotchUsagePresentation,
        geometry: NotchGeometry,
        expanded: Bool,
        notifications: NotchNotificationQueue,
        showingNotifications: Bool)
    {
        if showingNotifications != self.showingNotifications {
            self.tabForward = NotchAnimation.tabForward(from: self.showingNotifications, to: showingNotifications)
        }
        self.presentation = presentation
        self.geometry = geometry
        self.expanded = expanded
        self.notifications = notifications
        self.showingNotifications = showingNotifications
    }
}

@MainActor
final class NotchUsageController {
    private let providers: @MainActor () -> [NotchUsageProvider]
    private let openSettings: @MainActor () -> Void
    private var eventSource: NotchAgentEventSource?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchUsageView>?
    private var panelState: NotchPanelState?
    private var menuTracking = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notificationObserver: NSObjectProtocol?
    private var showAlertsObserver: NSObjectProtocol?
    private var pendingMakeKey = false
    private var lastAnnouncedNoticeID: UUID?
    private var lastAnnouncementAt: Date?
    private var hoverTask: Task<Void, Never>?
    private var notificationExpiryTask: Task<Void, Never>?
    private var freezeCapTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var dwellGeneration = 0
    private var shrinkGeneration = 0
    private var frameExpanded = false
    private let sleeper: NotchSleeper
    private var renderTask: Task<Void, Never>?
    private var observationGeneration = UUID()
    private var enabled = true
    private var running = false
    private var expanded = false {
        didSet {
            guard self.running, oldValue != self.expanded else { return }
            if self.expanded {
                self.cancelCollapseCompletion()
                self.frameExpanded = true
                self.freezeNotices()
            } else {
                self.cancelUnreadDwell()
                self.unfreezeNotices()
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.cancelCollapseCompletion()
                    self.frameExpanded = false
                } else {
                    self.scheduleCollapseCompletion()
                }
            }
        }
    }

    private var showingNotifications = false
    private var selectedID: String?
    private var notifications = NotchNotificationQueue()

    convenience init(store: UsageStore, settings _: SettingsStore, openSettings: @escaping @MainActor () -> Void) {
        self.init(providers: {
            _ = store.menuObservationToken
            return Self.providers(from: store)
        }, openSettings: openSettings)
    }

    init(
        providers: @escaping @MainActor () -> [NotchUsageProvider],
        openSettings: @escaping @MainActor () -> Void,
        eventFileURL: URL? = NotchAgentEventSource.defaultFileURL,
        sleeper: NotchSleeper = LiveNotchSleeper())
    {
        self.providers = providers
        self.openSettings = openSettings
        self.sleeper = sleeper
        self.eventSource = nil
        if let eventFileURL {
            self.eventSource = NotchAgentEventSource(fileURL: eventFileURL) { [weak self] event in
                self?.receive(event)
            }
        }
    }

    func start() {
        guard !self.running else { return }
        self.running = true
        self.observationGeneration = UUID()
        self.enabled = UserDefaults.standard.object(forKey: "notchUsageEnabled") as? Bool ?? true
        self.selectedID = UserDefaults.standard.string(forKey: "notchUsageSelectedProvider")
        self.eventSource?.start()
        for name in [NSApplication.didChangeScreenParametersNotification, UserDefaults.didChangeNotification] {
            self.observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main)
            { [weak self] notification in
                let defaultsChanged = notification.name == UserDefaults.didChangeNotification
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    if defaultsChanged {
                        let enabled = UserDefaults.standard.object(forKey: "notchUsageEnabled") as? Bool ?? true
                        guard enabled != self.enabled else { return }
                        self.enabled = enabled
                    }
                    self.requestRender()
                }
            })
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            self.observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main)
            { [weak self] notification in
                let tracking = notification.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuTracking = tracking
                    self.hoverTask?.cancel()
                    if !self.menuTracking, let panel = self.panel {
                        self.hoverChanged(panel.frame.contains(NSEvent.mouseLocation))
                    }
                }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            self.workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main)
            { [weak self] _ in
                MainActor.assumeIsolated { self?.requestRender() }
            })
        }
        self.notificationObserver = NotificationCenter.default.addObserver(
            forName: .codexBarCodingAgentNotification,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard let event = notification.object as? NotchCodingAgentNotification else { return }
            MainActor.assumeIsolated { self?.receive(event) }
        }
        self.showAlertsObserver = NotificationCenter.default.addObserver(
            forName: .codexBarShowNotchAlerts,
            object: nil,
            queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.showAlerts() }
        }
        self.observeStore()
        self.requestRender()
    }

    func stop() {
        self.running = false
        self.eventSource?.stop()
        self.observationGeneration = UUID()
        self.renderTask?.cancel()
        self.renderTask = nil
        self.hoverTask?.cancel()
        self.hoverTask = nil
        self.notificationExpiryTask?.cancel()
        self.notificationExpiryTask = nil
        self.freezeCapTask?.cancel()
        self.freezeCapTask = nil
        self.collapseTask?.cancel()
        self.collapseTask = nil
        self.cancelUnreadDwell()
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
            self.notificationObserver = nil
        }
        if let showAlertsObserver {
            NotificationCenter.default.removeObserver(showAlertsObserver)
            self.showAlertsObserver = nil
        }
        self.pendingMakeKey = false
        self.observers.forEach(NotificationCenter.default.removeObserver)
        self.observers.removeAll()
        self.workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        self.workspaceObservers.removeAll()
        self.panel?.orderOut(nil)
        self.panel = nil
        self.hostingView = nil
        self.panelState = nil
    }

    private func observeStore() {
        guard self.running else { return }
        let generation = self.observationGeneration
        withObservationTracking {
            _ = self.presentation()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.observationGeneration == generation else { return }
                self.observeStore()
                self.requestRender()
            }
        }
    }

    private func presentation() -> NotchUsagePresentation {
        let runningBundles = Set(NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
        let providers = self.providers().map { provider in
            var provider = provider
            provider.isAppRunning = provider.appIsRunning(in: runningBundles)
            return provider
        }
        return NotchUsagePresentation(providers: providers, selectedID: self.selectedID)
    }

    func receive(_ notification: NotchCodingAgentNotification, now: Date = Date()) {
        guard self.running, self.enabled else { return }
        self.notifications.enqueue(notification, now: now, countImmediately: self.expanded)
        if !self.expanded {
            self.scheduleNotificationExpiry()
            if self.frameExpanded {
                // Mid-collapse arrival: hold the large frame through the new
                // content instead of shrinking under it.
                self.scheduleCollapseCompletion()
            }
        }
        self.requestRender()
    }

    /// The non-click key path behind the status-menu Show Alerts item: opens
    /// the ALERTS tab and makes the panel key so T2 buttons are Full Keyboard
    /// Access operable and D/Esc act. Render is deferred, so keying rides a
    /// flag consumed by render once the panel is ordered front.
    func showAlerts() {
        guard self.running, self.enabled else { return }
        self.hoverTask?.cancel()
        self.pendingMakeKey = true
        self.showingNotifications = true
        self.expanded = true
        self.startUnreadDwell()
        self.requestRender()
    }

    private func advanceNotifications(now: Date = Date()) {
        self.notifications.advance(now: now)
        self.scheduleNotificationExpiry()
    }

    private func freezeNotices(now: Date = Date()) {
        self.notificationExpiryTask?.cancel()
        self.notificationExpiryTask = nil
        self.notifications.setExpanded(true, now: now)
        self.scheduleFreezeCap(now: now)
    }

    private func unfreezeNotices(now: Date = Date()) {
        self.freezeCapTask?.cancel()
        self.freezeCapTask = nil
        self.notifications.setExpanded(false, now: now)
        self.scheduleNotificationExpiry()
    }

    private func scheduleFreezeCap(now: Date = Date()) {
        self.freezeCapTask?.cancel()
        let remaining = max(0, NotchNotificationQueue.maxFrozenTime - self.notifications.frozenAccrued)
        self.freezeCapTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard let self, self.running, self.expanded else { return }
            self.freezeCapTask = nil
            self.notifications.forceRetainFrozen()
            self.requestRender()
        }
    }

    /// Asymmetric collapse ordering: the removal transition plays inside the
    /// old large frame first, then the frame shrinks on completion. The frame
    /// is recomputed from current state at fire time, so mid-collapse geometry
    /// changes land correctly.
    private func scheduleCollapseCompletion() {
        self.cancelCollapseCompletion()
        let generation = self.shrinkGeneration
        self.collapseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper.sleep(.milliseconds(Int(NotchAnimation.closeDuration * 1000)))
            } catch {
                return
            }
            guard NotchAnimation.shouldCompleteCollapse(
                firedGeneration: generation,
                currentGeneration: self.shrinkGeneration,
                running: self.running,
                expanded: self.expanded)
            else { return }
            self.collapseTask = nil
            self.frameExpanded = false
            self.render()
        }
    }

    private func cancelCollapseCompletion() {
        self.shrinkGeneration += 1
        self.collapseTask?.cancel()
        self.collapseTask = nil
    }

    private func scheduleNotificationExpiry() {
        self.notificationExpiryTask?.cancel()
        guard self.running, !self.expanded, let activeUntil = self.notifications.activeUntil else {
            self.notificationExpiryTask = nil
            return
        }
        let delay = max(0, activeUntil.timeIntervalSinceNow)
        self.notificationExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.running else { return }
            self.notificationExpiryTask = nil
            self.advanceNotifications()
            self.requestRender()
        }
    }

    /// Esc-first-dismiss: a visible banner goes first, collapse follows on
    /// the next Esc. Collapse-only when nothing is showing.
    private func handleEscape() {
        self.hoverTask?.cancel()
        if self.notifications.active != nil {
            self.dismissActiveNotice()
        } else {
            self.expanded = false
            self.requestRender()
        }
    }

    private func dismissActiveNotice(now: Date = Date()) {
        guard self.notifications.active != nil else { return }
        self.notifications.dismissActive(now: now)
        self.scheduleNotificationExpiry()
        self.requestRender()
    }

    /// Entering ALERTS arms a 1s dwell; the badge clears only if the panel is
    /// still expanded on ALERTS and front when it fires. Tab leave, collapse,
    /// and stop cancel via the generation bump.
    private func startUnreadDwell() {
        self.dwellTask?.cancel()
        self.dwellGeneration += 1
        let generation = self.dwellGeneration
        self.dwellTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, self.running else { return }
            self.dwellTask = nil
            guard NotchAnimation.shouldClearUnreadOnDwell(
                firedGeneration: generation,
                currentGeneration: self.dwellGeneration,
                expanded: self.expanded,
                showingNotifications: self.showingNotifications,
                panelFront: self.panel?.isVisible == true)
            else { return }
            self.notifications.markUnreadRead()
            self.requestRender()
        }
    }

    private func cancelUnreadDwell() {
        self.dwellGeneration += 1
        self.dwellTask?.cancel()
        self.dwellTask = nil
    }

    private static func providers(from store: UsageStore) -> [NotchUsageProvider] {
        store.enabledProvidersForDisplay().map { id in
            let snapshot = store.menuBarSnapshot(for: id)
            let metadata = id.firstPartyProvider.map { store.metadata(for: $0) }
            var name = metadata?.displayName ?? id.rawValue
            #if canImport(JavaScriptCore)
            if let plugin = UserProviderPluginRegistry.plugin(for: id) { name = plugin.manifest.name }
            #endif
            let windows = NotchUsageProvider.usageWindows(snapshot: snapshot, provider: id.firstPartyProvider)
            return NotchUsageProvider(
                id: id.rawValue,
                name: name,
                windows: windows,
                updatedAt: snapshot?.updatedAt,
                error: store.errors[id])
        }
    }

    /// Defer AppKit/SwiftUI layout out of notification and view callbacks. In particular,
    /// SwiftUI can itself write defaults while measuring text; synchronously rebuilding
    /// the hosting view from that notification recursively enters its layout locks.
    private func requestRender() {
        guard self.running, self.renderTask == nil else { return }
        self.renderTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.running else { return }
            self.renderTask = nil
            self.render()
        }
    }

    private func render() {
        guard self.running else { return }
        self.advanceNotifications()
        let geometry = NSScreen.screens.compactMap { screen in
            NotchGeometry(
                screenFrame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                leftArea: screen.auxiliaryTopLeftArea,
                rightArea: screen.auxiliaryTopRightArea)
        }.first
        guard self.enabled, let geometry else {
            self.hoverTask?.cancel()
            self.expanded = false
            self.pendingMakeKey = false
            self.panel?.orderOut(nil)
            return
        }
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NotchUsagePanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            (panel as? NotchUsagePanel)?.dismiss = { [weak self] in
                self?.handleEscape()
            }
            (panel as? NotchUsagePanel)?.dismissNotice = { [weak self] in
                self?.dismissActiveNotice()
            }
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.setAccessibilityLabel("CodexBar notch usage")
            self.panel = panel
        }
        let presentation = self.presentation()
        // The frame follows frameExpanded (not expanded): on collapse the
        // removal transition plays inside the old large frame, which shrinks
        // when the collapse-completion task fires. Under Reduce Motion both
        // flip together, keeping the hit region equal to visible bounds.
        panel.setFrame(
            geometry.frame(
                expanded: self.frameExpanded,
                notificationVisible: self.notifications.active != nil,
                expandingNoticeVisible: self.notifications.active?.showsExpanded == true),
            display: false)
        if let state = self.panelState {
            state.update(
                presentation: presentation,
                geometry: geometry,
                expanded: self.expanded,
                notifications: self.notifications,
                showingNotifications: self.showingNotifications)
        } else {
            let state = NotchPanelState(
                presentation: presentation,
                geometry: geometry,
                expanded: self.expanded,
                notifications: self.notifications,
                showingNotifications: self.showingNotifications)
            self.panelState = state
            let view = NotchUsageView(
                state: state,
                selectProvider: { [weak self] id in
                    guard let self else { return }
                    self.selectedID = id
                    self.showingNotifications = false
                    self.cancelUnreadDwell()
                    UserDefaults.standard.set(id, forKey: "notchUsageSelectedProvider")
                    self.requestRender()
                },
                toggleExpanded: { [weak self] in
                    guard let self else { return }
                    self.hoverTask?.cancel()
                    self.expanded.toggle()
                    self.requestRender()
                },
                hoverChanged: { [weak self] inside in
                    self?.hoverChanged(inside)
                },
                openSettings: { [weak self] in
                    guard let self else { return }
                    self.hoverTask?.cancel()
                    self.expanded = false
                    self.requestRender()
                    self.openSettings()
                },
                openNotifications: { [weak self] in
                    guard let self else { return }
                    self.hoverTask?.cancel()
                    self.showingNotifications = true
                    self.expanded = true
                    self.startUnreadDwell()
                    self.requestRender()
                },
                dismissNotification: { [weak self] in
                    self?.dismissActiveNotice()
                })
            let hostingView = NotchHostingView(rootView: view)
            panel.contentView = hostingView
            self.hostingView = hostingView
        }
        panel.orderFrontRegardless()
        if self.pendingMakeKey {
            self.pendingMakeKey = false
            panel.makeKey()
        }
        self.announceNoticeIfNeeded()
    }

    /// VoiceOver announcement on banner title change: leading-edge throttled
    /// to max 1 per 5s. The visual banner subtree is accessibility-hidden; the
    /// text is mirrored on a dedicated announcement-only element in the view.
    private func announceNoticeIfNeeded(now: Date = Date()) {
        let activeID = self.notifications.active?.id
        guard activeID != self.lastAnnouncedNoticeID else { return }
        self.lastAnnouncedNoticeID = activeID
        guard let notice = self.notifications.active,
              let panel = self.panel,
              NotchAnimation.shouldAnnounce(now: now, lastAnnouncement: self.lastAnnouncementAt)
        else { return }
        self.lastAnnouncementAt = now
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [.announcement: notice.announcementText])
    }

    private func hoverChanged(_ inside: Bool) {
        self.hoverTask?.cancel()
        guard !self.menuTracking, inside != self.expanded else { return }
        self.hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(inside ? 220 : 400)) } catch { return }
            guard let self, self.running else { return }
            self.expanded = inside
            self.requestRender()
        }
    }
}

@MainActor
private final class NotchUsagePanel: NSPanel {
    var dismiss: (() -> Void)?
    var dismissNotice: (() -> Void)?
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        self.dismiss?()
        self.resignKey()
    }

    /// D-once-keyed dismisses the visible notice (Esc-first-dismiss parity).
    /// Unkeyed, neither key reaches the panel, so both are no-ops there.
    override func keyDown(with event: NSEvent) {
        let hasModifiers = !event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        if NotchAnimation.isNoticeDismissKeyPress(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            hasModifiers: hasModifiers)
        {
            self.dismissNotice?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class NotchHostingView: NSHostingView<NotchUsageView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
