import AppKit
import CodexBarCore
import Foundation

/// Notice event kind: hook agent events plus producer-built quota and login notices.
/// Agent raw values match the hook payload `type` strings exactly; quota and login
/// raw values are never parsed from hooks (see `isHookType`) and are minted only
/// by the producers below.
enum NotchAgentEventType: String, Sendable {
    case completed
    case failed
    case waiting
    case accessRequest = "access_request"
    case quotaDepleted = "quota_depleted"
    case quotaWarning = "quota_warning"
    case quotaRestored = "quota_restored"
    case creditExpiry = "credit_expiry"
    case predictiveWarning = "predictive_warning"
    case loginFailure = "login_failure"

    /// Only the four agent kinds may arrive via the hook feed. Quota and login
    /// raw values stay rejected there, preserving unknown-type rejection.
    var isHookType: Bool {
        switch self {
        case .completed, .failed, .waiting, .accessRequest: true
        case .quotaDepleted, .quotaWarning, .quotaRestored, .creditExpiry, .predictiveWarning, .loginFailure: false
        }
    }

    /// Severity-lane routing per the §4 table. Pure so the mapping is tested
    /// without a queue or the filesystem.
    var severity: NotchNotificationSeverity {
        switch self {
        case .completed, .quotaRestored: .info
        case .waiting, .failed, .quotaWarning, .creditExpiry, .predictiveWarning: .warning
        case .accessRequest, .quotaDepleted, .loginFailure: .critical
        }
    }

    /// Presentation tier per the §4 table: access_request, quota depleted, and
    /// login failure take over the notch (T2); every other event is a T1 sneak peek.
    var noticeTier: NotchNoticeTier {
        switch self {
        case .accessRequest, .quotaDepleted, .loginFailure: .expanding
        case .completed, .waiting, .failed, .quotaWarning, .quotaRestored, .creditExpiry, .predictiveWarning: .sneakPeek
        }
    }

    /// Severity icon shape per the §4 table. Never color-only: the label
    /// alongside always names the level for grayscale and assistive tech.
    var symbolName: String {
        switch self {
        case .completed, .quotaRestored: "checkmark.circle"
        case .waiting: "ellipsis.circle"
        case .failed: "exclamationmark.triangle"
        case .accessRequest: "questionmark.circle"
        case .quotaDepleted: "exclamationmark.octagon"
        case .quotaWarning, .predictiveWarning: "gauge.with.dots.needle.50percent"
        case .creditExpiry: "hourglass"
        case .loginFailure: "person.crop.circle.badge.xmark"
        }
    }

    /// Severity text label per the §4 table.
    var severityLabel: String {
        switch self {
        case .completed: "Done"
        case .waiting: "Waiting"
        case .failed: "Failed"
        case .accessRequest: "Needs approval"
        case .quotaDepleted: "Limit reached"
        case .quotaWarning, .predictiveWarning: "Running low"
        case .quotaRestored: "Restored"
        case .creditExpiry: "Expiring"
        case .loginFailure: "Sign-in failed"
        }
    }
}

/// Presentation tier for the active item: a T1 sneak peek or the taller
/// T2 expanding takeover.
enum NotchNoticeTier: Sendable, Equatable {
    case sneakPeek
    case expanding
}

/// Severity lanes order info < warning < critical.
enum NotchNotificationSeverity: Sendable, Comparable {
    case info
    case warning
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }
}

/// A notification emitted by a supported coding-agent hook source.
///
/// The notch reads the existing local Notchly hook feed. It never reads another
/// app's notification center or infers alerts from session activity.
struct NotchCodingAgentNotification: Equatable, Identifiable, Sendable {
    let id: UUID
    let provider: String
    let type: NotchAgentEventType
    var count: Int
    let title: String
    let message: String
    let createdAt: Date

    var severity: NotchNotificationSeverity {
        self.type.severity
    }

    var noticeTier: NotchNoticeTier {
        self.type.noticeTier
    }

    /// Expanded-tier items get the longer base window and reshow floor.
    var showsExpanded: Bool {
        self.noticeTier == .expanding
    }

    var tierBase: TimeInterval {
        self.showsExpanded
            ? NotchNotificationQueue.expandedDisplayDuration
            : NotchNotificationQueue.displayDuration
    }

    var tierFloor: TimeInterval {
        self.showsExpanded
            ? NotchNotificationQueue.expandedReshowFloor
            : NotchNotificationQueue.reshowFloor
    }

    /// Coalescing identity: identical provider, type, and title share one entry.
    func matches(_ other: NotchCodingAgentNotification) -> Bool {
        self.provider == other.provider && self.type == other.type && self.title == other.title
    }

    /// VoiceOver announcement: provider, severity label, title (with the
    /// coalesced count the banner shows), and message. Spoken via
    /// announcementRequested and mirrored on the dedicated announcement-only
    /// accessibility element while the visual banner subtree stays hidden.
    var announcementText: String {
        let title = self.count > 1 ? "\(self.title) ×\(self.count)" : self.title
        return [self.provider, self.type.severityLabel, title, self.message]
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
    }

    init(
        id: UUID = UUID(),
        provider: String,
        type: NotchAgentEventType = .completed,
        count: Int = 1,
        title: String,
        message: String,
        createdAt: Date = Date())
    {
        self.id = id
        self.provider = provider
        self.type = type
        self.count = count
        self.title = title
        self.message = message
        self.createdAt = createdAt
    }
}

extension Notification.Name {
    static let codexBarCodingAgentNotification = Notification.Name("CodexBar.codingAgentNotification")
    static let codexBarShowNotchAlerts = Notification.Name("CodexBar.showNotchAlerts")
}

/// Quota and login producers build notch notices with the same copy as their
/// OS banner or modal and route them through the existing NotificationCenter
/// path to `NotchUsageController.receive`. Pure factories so mappings are
/// tested without a queue, the filesystem, or notification services.
extension NotchCodingAgentNotification {
    init(quotaTransition transition: SessionQuotaTransition, providerName: String, now: Date = Date()) {
        let copy = SessionQuotaNotificationLogic.notificationCopy(transition: transition, providerName: providerName)
        self.init(
            provider: providerName,
            type: transition == .depleted ? .quotaDepleted : .quotaRestored,
            title: copy.title,
            message: copy.body,
            createdAt: now)
    }

    init(quotaWarning event: QuotaWarningEvent, providerName: String, now: Date = Date()) {
        let copy = QuotaWarningNotificationLogic.notificationCopy(
            providerName: providerName,
            window: event.window,
            threshold: event.threshold,
            currentRemaining: event.currentRemaining,
            accountDisplayName: event.accountDisplayName,
            windowDisplayLabel: event.windowDisplayLabel)
        self.init(provider: providerName, type: .quotaWarning, title: copy.title, message: copy.body, createdAt: now)
    }

    init(predictivePaceWarning event: PredictivePaceWarningEvent, providerName: String, now: Date = Date()) {
        let copy = PredictivePaceWarningNotificationLogic.notificationCopy(
            providerName: providerName,
            event: event,
            now: now)
        self.init(
            provider: providerName,
            type: .predictiveWarning,
            title: copy.title,
            message: copy.body,
            createdAt: now)
    }

    init(creditExpiryTitle title: String, body: String, providerName: String, now: Date = Date()) {
        self.init(provider: providerName, type: .creditExpiry, title: title, message: body, createdAt: now)
    }

    /// Login-failure notices reuse the modal's resolved copy so the T2 banner
    /// and the alert always agree. Pure so the mapping is tested without a
    /// modal, the queue, or notification services.
    init(loginFailureTitle title: String, body: String, provider: UsageProvider, now: Date = Date()) {
        self.init(
            provider: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName,
            type: .loginFailure,
            title: title,
            message: body,
            createdAt: now)
    }
}

/// Login-failure notch notices are additive (the modal still shows) and
/// reversible via this flag. Overnight default: on — confirm in morning
/// review whether the T2 earns its place alongside the modal.
enum NotchLoginFailureNotices {
    static let enabledDefaultsKey = "notchLoginFailureNoticesEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: self.enabledDefaultsKey) as? Bool ?? true
    }
}

enum NotchQuotaNoticeRouting {
    static func post(_ notification: NotchCodingAgentNotification) {
        NotificationCenter.default.post(name: .codexBarCodingAgentNotification, object: notification)
    }
}

/// Single-channel rule (§5 trigger table): the OS banner posts iff the notch
/// cannot show — disabled, no notch geometry, or screen locked. Fullscreen is
/// deliberately not a trigger: the panel is `.fullScreenAuxiliary` and already
/// shows over fullscreen. Pure so the predicate is tested without screens or
/// the lock daemon.
struct NotchNoticeChannelPolicy: Sendable, Equatable {
    var notchEnabled: Bool
    var geometryAvailable: Bool
    var screenLocked: Bool

    /// True when T1/T2 will show, so the OS post must be suppressed.
    var showsNotchNotice: Bool {
        self.notchEnabled && self.geometryAvailable && !self.screenLocked
    }

    @MainActor static var live: Self {
        Self(
            notchEnabled: UserDefaults.standard.object(forKey: "notchUsageEnabled") as? Bool ?? true,
            geometryAvailable: hasNotchGeometry(),
            screenLocked: ScreenLockMonitor.shared.isLocked)
    }

    @MainActor private static func hasNotchGeometry() -> Bool {
        NSScreen.screens.contains { screen in
            NotchGeometry(
                screenFrame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                leftArea: screen.auxiliaryTopLeftArea,
                rightArea: screen.auxiliaryTopRightArea)
                != nil
        }
    }
}

/// Tracks screen-lock state via DistributedNotificationCenter so the
/// single-channel rule falls back to OS banners while locked.
@MainActor
final class ScreenLockMonitor {
    static let lockedName = NSNotification.Name("com.apple.screenIsLocked")
    static let unlockedName = NSNotification.Name("com.apple.screenIsUnlocked")
    static let shared = ScreenLockMonitor()

    private(set) var isLocked = false

    init(center: DistributedNotificationCenter = .default()) {
        // The shared monitor lives forever; test instances rely on weak self
        // so leaked registrations stay harmless after deallocation.
        for (name, locked) in [(Self.lockedName, true), (Self.unlockedName, false)] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleLockChange(locked: locked) }
            }
        }
    }

    func handleLockChange(locked: Bool) {
        self.isLocked = locked
    }
}

/// In-memory queue for the compact notch notification row.
///
/// A launch starts empty. The active item gets a complete window (ten seconds,
/// fifteen for expanded-tier items); queued items do not begin their own window
/// until the preceding item expires. Criticals preempt the active window within
/// the fairness and rate caps below. Pending is severity-lane-ordered
/// (criticals ahead of warnings ahead of infos, FIFO within a lane) and
/// selection scans lanes rather than taking the head.
///
/// Freeze exception: while the panel is expanded the active countdown is
/// frozen — arrivals queue to pending instead of showing or preempting, and
/// `advance` is a no-op. Total frozen time per active item is capped; past the
/// cap the item retains and the countdown never resumes.
struct NotchNotificationQueue: Equatable {
    static let displayDuration: TimeInterval = 10
    static let expandedDisplayDuration: TimeInterval = 15
    static let reshowFloor: TimeInterval = 5
    static let expandedReshowFloor: TimeInterval = 10
    static let maxDwellMultiplier = 2.0
    static let maxPendingCount = 50
    static let maxRetainedCount = 50
    static let maxConsecutiveCriticalShows = 2
    static let maxPreemptionsPerMinute = 4
    static let maxBannersPerMinutePerProvider = 3
    static let rateWindow: TimeInterval = 60
    static let maxFrozenTime: TimeInterval = 60
    static let minimumReshowDuration: TimeInterval = 1

    private static let logger = CodexBarLog.logger(LogCategories.notifications)

    private(set) var active: NotchCodingAgentNotification?
    private(set) var activeUntil: Date?
    private(set) var activeSince: Date?
    private(set) var pending: [NotchCodingAgentNotification] = []
    private(set) var retained: [NotchCodingAgentNotification] = []
    private(set) var unreadCount = 0
    private(set) var consecutiveCriticalShows = 0
    private(set) var isFrozen = false
    private(set) var frozenAccrued: TimeInterval = 0

    private var remainingByID: [UUID: TimeInterval] = [:]
    private var shownSoFarByID: [UUID: TimeInterval] = [:]
    private var preemptionMoments: [Date] = []
    private var bannerMomentsByProvider: [String: [Date]] = [:]
    private var countedIDs: Set<UUID> = []
    private var freezeStart: Date?

    init() {}

    mutating func enqueue(_ notification: NotchCodingAgentNotification, now: Date, countImmediately: Bool = false) {
        self.advance(now: now)
        if let current = self.active, current.matches(notification) {
            self.active?.count += notification.count
            if countImmediately, let id = self.active?.id {
                self.countOnce(id)
            }
            return
        }
        if self.active == nil, !self.isFrozen {
            self.showFreshOrOverflow(notification, now: now)
        } else if !self.isFrozen,
                  notification.severity == .critical,
                  self.preemptionAllowed()
        {
            self.preempt(with: notification, now: now)
        } else {
            self.insertLaneOrdered(notification)
            if countImmediately {
                self.countOnce(notification.id)
            }
            self.evictPendingOverflow()
        }
    }

    mutating func advance(now: Date) {
        guard !self.isFrozen else { return }
        guard let active, let activeUntil, now >= activeUntil else { return }
        self.retainCounted(active)
        self.active = nil
        self.activeUntil = nil
        self.activeSince = nil

        guard !self.pending.isEmpty else {
            self.consecutiveCriticalShows = 0
            return
        }
        self.promoteNext(now: now)
    }

    /// Freeze or unfreeze the active countdown around panel expansion.
    /// Collapse extends the window by the frozen span and pumps the next item
    /// when freeze-cap death left the banner idle.
    mutating func setExpanded(_ expanded: Bool, now: Date) {
        if expanded {
            guard !self.isFrozen else { return }
            self.isFrozen = true
            self.freezeStart = now
        } else {
            guard self.isFrozen else { return }
            self.isFrozen = false
            if let start = self.freezeStart {
                let elapsed = max(0, now.timeIntervalSince(start))
                self.frozenAccrued += elapsed
                self.activeUntil = self.activeUntil?.addingTimeInterval(elapsed)
                self.freezeStart = nil
            }
            if self.active == nil, !self.pending.isEmpty {
                self.promoteNext(now: now)
            }
        }
    }

    /// Manual dismissal (T2 Dismiss button or Esc-first): the active item
    /// retains and counts once, then the next pending item shows immediately.
    /// The dismissed item is fully dead — no reshow, no resumed countdown.
    /// Works while frozen; a promoted item simply inherits the freeze.
    mutating func dismissActive(now: Date) {
        guard let current = self.active else { return }
        self.retainCounted(current)
        self.active = nil
        self.activeUntil = nil
        self.activeSince = nil

        guard !self.pending.isEmpty else {
            self.consecutiveCriticalShows = 0
            return
        }
        self.promoteNext(now: now)
    }

    /// Freeze-cap death: the item retains and counts once, then is fully dead —
    /// no reshow, no resumed countdown, no second count.
    mutating func forceRetainFrozen() {
        guard self.isFrozen, let current = self.active else { return }
        self.retainCounted(current)
        self.active = nil
        self.activeUntil = nil
        self.activeSince = nil
    }

    private mutating func showFreshOrOverflow(_ notification: NotchCodingAgentNotification, now: Date) {
        if self.bannerAllowed(provider: notification.provider, now: now) {
            self.activate(notification, duration: notification.tierBase, now: now, fresh: true)
        } else {
            self.overflow(notification, tripped: "frequency")
        }
    }

    private mutating func preempt(with notification: NotchCodingAgentNotification, now: Date) {
        self.prunePreemptionMoments(now: now)
        guard self.preemptionMoments.count < Self.maxPreemptionsPerMinute else {
            self.overflow(notification, tripped: "preemption-cap")
            return
        }
        guard self.bannerAllowed(provider: notification.provider, now: now) else {
            self.overflow(notification, tripped: "frequency")
            return
        }
        if let current = self.active,
           let until = self.activeUntil,
           let since = self.activeSince
        {
            self.shownSoFarByID[current.id, default: 0] += max(0, now.timeIntervalSince(since))
            self.remainingByID[current.id] = max(1, until.timeIntervalSince(now))
            self.insertLaneOrdered(current)
            self.evictPendingOverflow()
        }
        self.preemptionMoments.append(now)
        self.activate(notification, duration: notification.tierBase, now: now, fresh: true)
    }

    /// Preemption is suppressed once two fresh criticals have shown in a row
    /// while an info or warning is still waiting, so fairness can serve it next.
    private func preemptionAllowed() -> Bool {
        guard self.consecutiveCriticalShows >= Self.maxConsecutiveCriticalShows else { return true }
        return !self.pending.contains { $0.severity < .critical }
    }

    private mutating func promoteNext(now: Date) {
        while let index = self.selectionIndex() {
            let next = self.pending.remove(at: index)
            let remaining = self.remainingByID.removeValue(forKey: next.id)
            // Shown time survives promotion: a reshow that is preempted again
            // must keep accumulating toward the total-dwell cap. It clears only
            // when the item is retained or evicted.
            let shown = self.shownSoFarByID[next.id] ?? 0
            let duration: TimeInterval
            if let remaining {
                let allowed = next.tierBase * Self.maxDwellMultiplier - shown
                guard allowed >= Self.minimumReshowDuration else {
                    self.retainCounted(next)
                    continue
                }
                duration = min(max(remaining, next.tierFloor), allowed)
            } else {
                duration = next.tierBase
            }
            guard self.bannerAllowed(provider: next.provider, now: now) else {
                self.overflow(next, tripped: "frequency")
                continue
            }
            self.activate(next, duration: duration, now: now, fresh: remaining == nil)
            return
        }
    }

    private func selectionIndex() -> Int? {
        if self.consecutiveCriticalShows >= Self.maxConsecutiveCriticalShows,
           let fair = self.pending.firstIndex(where: { $0.severity < .critical })
        {
            return fair
        }
        return self.highestSeverityIndex()
    }

    private mutating func activate(
        _ notification: NotchCodingAgentNotification,
        duration: TimeInterval,
        now: Date,
        fresh: Bool)
    {
        self.active = notification
        self.activeSince = now
        self.activeUntil = now.addingTimeInterval(duration)
        self.frozenAccrued = 0
        self.recordBannerMoment(provider: notification.provider, now: now)
        guard fresh else { return }
        if notification.severity == .critical {
            self.consecutiveCriticalShows += 1
        } else {
            self.consecutiveCriticalShows = 0
        }
    }

    /// Single overflow path: merge into an identical retained entry when one
    /// exists, else append. Either way the item counts once and never shows.
    private mutating func overflow(_ notification: NotchCodingAgentNotification, tripped cap: String) {
        self.retainCounted(notification)
        Self.logger.debug("notice cap trip", metadata: ["cap": cap, "provider": notification.provider])
    }

    /// Retains, merging into an identical entry (bumping its count) when one
    /// exists. Returns whether the item landed as a new entry.
    @discardableResult
    private mutating func mergeContent(_ notification: NotchCodingAgentNotification) -> Bool {
        if let index = self.retained.firstIndex(where: { $0.matches(notification) }) {
            self.retained[index].count += notification.count
            return false
        }
        self.retained.append(notification)
        while self.retained.count > Self.maxRetainedCount {
            let dropped = self.retained.removeFirst()
            self.countedIDs.remove(dropped.id)
            self.clearPerItemState(for: dropped.id)
        }
        return true
    }

    private mutating func retainCounted(_ notification: NotchCodingAgentNotification) {
        let appended = self.mergeContent(notification)
        self.countOnce(notification.id)
        if !appended {
            // Merged into an older entry: the count is granted but this id is
            // gone, so drop it instead of pinning it in the counted set.
            self.countedIDs.remove(notification.id)
        }
        self.clearPerItemState(for: notification.id)
    }

    /// Grants the unread increment at most once per id.
    private mutating func countOnce(_ id: UUID) {
        guard !self.countedIDs.contains(id) else { return }
        self.countedIDs.insert(id)
        self.unreadCount = min(Self.maxRetainedCount, self.unreadCount + 1)
    }

    private mutating func evictPendingOverflow() {
        while self.pending.count > Self.maxPendingCount {
            // Evict the lowest-severity tail so capped lanes keep the items
            // the user most needs to see. Eviction counts once, then the id is
            // dropped with the item instead of pinning the counted set.
            let dropped = self.pending.removeLast()
            self.countOnce(dropped.id)
            self.countedIDs.remove(dropped.id)
            self.clearPerItemState(for: dropped.id)
        }
    }

    private mutating func clearPerItemState(for id: UUID) {
        self.remainingByID.removeValue(forKey: id)
        self.shownSoFarByID.removeValue(forKey: id)
    }

    private mutating func bannerAllowed(provider: String, now: Date) -> Bool {
        self.pruneBannerMoments(provider: provider, now: now)
        return (self.bannerMomentsByProvider[provider]?.count ?? 0) < Self.maxBannersPerMinutePerProvider
    }

    private mutating func recordBannerMoment(provider: String, now: Date) {
        self.pruneBannerMoments(provider: provider, now: now)
        self.bannerMomentsByProvider[provider, default: []].append(now)
    }

    private mutating func pruneBannerMoments(provider: String, now: Date) {
        let cutoff = now.addingTimeInterval(-Self.rateWindow)
        self.bannerMomentsByProvider[provider]?.removeAll { $0 <= cutoff }
        if self.bannerMomentsByProvider[provider]?.isEmpty == true {
            self.bannerMomentsByProvider.removeValue(forKey: provider)
        }
    }

    private mutating func prunePreemptionMoments(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.rateWindow)
        self.preemptionMoments.removeAll { $0 <= cutoff }
    }

    /// Stable lane-ordered insert: lands behind same-or-higher-severity items,
    /// so each lane stays FIFO.
    private mutating func insertLaneOrdered(_ notification: NotchCodingAgentNotification) {
        let index = self.pending.firstIndex { $0.severity < notification.severity } ?? self.pending.endIndex
        self.pending.insert(notification, at: index)
    }

    /// Lane scan: first index of the highest pending severity, or nil when empty.
    private func highestSeverityIndex() -> Int? {
        var best: Int?
        for index in self.pending.indices {
            guard let current = best else {
                best = index
                continue
            }
            if self.pending[current].severity < self.pending[index].severity {
                best = index
            }
        }
        return best
    }

    mutating func markUnreadRead() {
        self.unreadCount = 0
    }

    /// Highest severity among waiting/access_request items in active+pending.
    /// Retained history never marks: aged-out items must not nag.
    var pendingMarker: NotchNotificationSeverity? {
        let live = ([self.active].compactMap(\.self) + self.pending).filter {
            $0.type == .waiting || $0.type == .accessRequest
        }
        return live.map(\.severity).max()
    }
}

/// Tails the event file written by the existing local agent hook integrations.
///
/// The initial file position is always the current end, so old events never
/// become startup alerts. Reads are bounded and tolerate partial JSONL writes,
/// truncation, and file replacement.
@MainActor
final class NotchAgentEventSource {
    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Notchly/agent-events.jsonl")
    private static let pollInterval: Duration = .seconds(1)
    private static let maxReadBytes = 64 * 1024
    private static let maxLineBytes = 16 * 1024

    private struct Payload: Decodable {
        let source: String?
        let type: String?
        let title: String?
        let message: String?
    }

    private let fileURL: URL
    private let onEvent: @MainActor (NotchCodingAgentNotification) -> Void
    private var task: Task<Void, Never>?
    private var fileOffset: UInt64?
    private var fileIdentity: String?
    private var bufferedData = Data()

    init(
        fileURL: URL = NotchAgentEventSource.defaultFileURL,
        onEvent: @escaping @MainActor (NotchCodingAgentNotification) -> Void)
    {
        self.fileURL = fileURL
        self.onEvent = onEvent
    }

    deinit {
        self.task?.cancel()
    }

    func start() {
        guard self.task == nil else { return }
        self.primeReadPosition()
        self.task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        self.task?.cancel()
        self.task = nil
        self.bufferedData.removeAll(keepingCapacity: false)
    }

    /// Poll once without starting the repeating task. This keeps file-tail behavior
    /// deterministic in focused tests while the app continues to use `start()`.
    func pollForTesting(now: Date = Date()) {
        self.poll(now: now)
    }

    /// Parses one bounded JSONL payload. Kept pure so hook semantics are tested
    /// without touching another app, the filesystem, or notification services.
    static func notification(from line: Data, now: Date) -> NotchCodingAgentNotification? {
        guard line.count <= self.maxLineBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: line),
              let rawSource = payload.source?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rawType = payload.type?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSource.isEmpty,
              !rawType.isEmpty
        else { return nil }

        let source = rawSource.lowercased()
        // Provider-specific by design: only the installed Claude, Codex, and Cursor hooks emit this event schema.
        guard ["claude", "codex", "cursor"].contains(source),
              let type = NotchAgentEventType(rawValue: rawType.lowercased()),
              type.isHookType
        else { return nil }

        let title = Self.sanitize(payload.title)
        let message = Self.sanitize(payload.message)
        guard title != nil || message != nil else { return nil }
        let provider = switch source {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "cursor": "Cursor"
        default: source.capitalized
        }
        return NotchCodingAgentNotification(
            provider: provider,
            type: type,
            title: title ?? rawType.replacingOccurrences(of: "_", with: " ").capitalized,
            message: message ?? "",
            createdAt: now)
    }

    private func primeReadPosition() {
        guard let metadata = self.metadata() else {
            // No file at launch means the first file created by a hook is new
            // input, so begin at offset zero when it appears.
            self.fileOffset = 0
            self.fileIdentity = nil
            return
        }
        self.fileOffset = metadata.size
        self.fileIdentity = metadata.identity
        self.bufferedData.removeAll(keepingCapacity: false)
    }

    private func poll(now: Date = Date()) {
        guard let metadata = self.metadata() else {
            // Preserve an offset of zero so a file created after launch is
            // parsed from its beginning rather than treated as old history.
            self.fileOffset = 0
            self.fileIdentity = nil
            self.bufferedData.removeAll(keepingCapacity: false)
            return
        }

        guard var offset = self.fileOffset else {
            // The file appeared after startup. Skip its existing history and wait
            // for a newly appended line.
            self.fileOffset = metadata.size
            self.fileIdentity = metadata.identity
            return
        }
        if self.fileIdentity != metadata.identity {
            offset = 0
            self.bufferedData.removeAll(keepingCapacity: false)
            self.fileIdentity = metadata.identity
        } else if metadata.size < offset {
            offset = 0
            self.bufferedData.removeAll(keepingCapacity: false)
        }

        guard metadata.size > offset,
              let handle = try? FileHandle(forReadingFrom: self.fileURL)
        else {
            self.fileOffset = offset
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let byteCount = min(Self.maxReadBytes, Int(metadata.size - offset))
            guard let data = try handle.read(upToCount: byteCount), !data.isEmpty else {
                self.fileOffset = offset
                return
            }
            offset += UInt64(data.count)
            self.fileOffset = offset
            self.consume(data, now: now)
        } catch {
            self.fileOffset = offset
        }
    }

    private func consume(_ data: Data, now: Date) {
        self.bufferedData.append(data)
        while let newline = self.bufferedData.firstIndex(of: 0x0A) {
            let line = self.bufferedData.prefix(upTo: newline)
            self.bufferedData.removeSubrange(...newline)
            guard !line.isEmpty, line.count <= Self.maxLineBytes else { continue }
            if let event = Self.notification(from: Data(line), now: now) {
                self.onEvent(event)
            }
        }
        if self.bufferedData.count > Self.maxLineBytes {
            self.bufferedData.removeAll(keepingCapacity: false)
        }
    }

    private func metadata() -> (size: UInt64, identity: String)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: self.fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= 0
        else { return nil }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let identity = inode.map { "\(device):\($0)" } ?? self.fileURL.path
        return (fileSize.uint64Value, identity)
    }

    private static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .prefix(160)
        let value = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
