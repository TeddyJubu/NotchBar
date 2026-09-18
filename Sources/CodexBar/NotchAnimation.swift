import SwiftUI

/// Motion tokens for the notch panel.
///
/// P0a ships the selectors only; call sites land in P1a+. Every token uses
/// macOS 14 APIs. Views read `@Environment(\.accessibilityReduceMotion)` and
/// pass the Bool in, since a tokens module cannot host `@Environment` itself.
/// Under Reduce Motion every animation selector returns nil (instant) and
/// every transition selector returns `.identity`, per the per-site mapping in
/// docs/notch-notices-animation-plan.md §6.
enum NotchAnimation {
    static func open(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 1.0)
    }

    static func close(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
    }

    static func content(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth
    }

    static func swapInsertionAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88)
    }

    static func swapRemovalAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    static func consecutiveSwapAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .interactiveSpring(dampingFraction: 1.2)
    }

    static func tabAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3)
    }

    /// Settle allowance for the close spring, consumed by both the close
    /// animation and (in P1a) the collapse-completion scheduler. This is an
    /// estimate, not the response value: P1a confirms the constant in proof.
    static let closeDuration: TimeInterval = 0.75

    static func swapInsertion(reduceMotion: Bool) -> NotchTransition {
        reduceMotion ? .identity : .swapInsertion
    }

    static func swapRemoval(reduceMotion: Bool) -> NotchTransition {
        reduceMotion ? .identity : .swapRemoval
    }

    static func consecutiveSwap(reduceMotion: Bool) -> NotchTransition {
        reduceMotion ? .identity : .consecutiveSwap
    }

    /// Closed-notch live swap as one asymmetric token: insertion pops in,
    /// removal shrinks out.
    static func swapTransition(reduceMotion: Bool) -> NotchTransition {
        reduceMotion ? .identity : .swap
    }

    /// T-minus hairline fraction: 1 at show, 0 at expiry, clamped.
    static func hairlineFraction(now: Date, since: Date, until: Date) -> Double {
        guard until > since else { return 0 }
        return min(1, max(0, until.timeIntervalSince(now) / until.timeIntervalSince(since)))
    }

    /// Identity key for the unread badge: bumping the count replaces the view
    /// so the swap transition pops on every increment.
    static func badgeID(_ unreadCount: Int) -> String {
        "unread-\(unreadCount)"
    }

    /// Marquee gate: scroll only when the text overflows its frame and motion
    /// is allowed. Zero widths (unmeasured) never scroll.
    static func marqueeScrolls(textWidth: CGFloat, frameWidth: CGFloat, reduceMotion: Bool) -> Bool {
        !reduceMotion && textWidth > 0 && frameWidth > 0 && textWidth > frameWidth
    }

    /// Coalescing suffix for banner titles: blank for singletons.
    static func countSuffix(_ count: Int) -> String {
        count > 1 ? " ×\(count)" : ""
    }

    /// Collapse-completion guard: a stale shrink (superseded generation,
    /// re-expanded panel, stopped controller) must never resize the frame.
    static func shouldCompleteCollapse(
        firedGeneration: Int,
        currentGeneration: Int,
        running: Bool,
        expanded: Bool)
        -> Bool
    {
        running && !expanded && firedGeneration == currentGeneration
    }

    static func tab(forward: Bool, reduceMotion: Bool) -> NotchTransition {
        if reduceMotion {
            return .identity
        }
        return forward ? .tabForward : .tabBackward
    }

    /// Dwell read-marking guard: the badge clears only when the dwell task is
    /// still the live generation and the panel is expanded on ALERTS and
    /// ordered front. Tab leave and collapse bump the generation, so a stale
    /// fire (superseded dwell) never clears.
    static func shouldClearUnreadOnDwell(
        firedGeneration: Int,
        currentGeneration: Int,
        expanded: Bool,
        showingNotifications: Bool,
        panelFront: Bool)
        -> Bool
    {
        firedGeneration == currentGeneration && expanded && showingNotifications && panelFront
    }

    /// Expanded-tab index: USAGE is 0, ALERTS is 1.
    static func tabIndex(showingNotifications: Bool) -> Int {
        showingNotifications ? 1 : 0
    }

    /// Directional tab derivation: navigating toward the higher index slides
    /// forward, toward the lower index slides back.
    static func tabForward(from previous: Bool, to current: Bool) -> Bool {
        self.tabIndex(showingNotifications: current) > self.tabIndex(showingNotifications: previous)
    }

    /// VoiceOver announcement throttle: leading edge, max 1 per 5s. Burst
    /// titles beyond the first are dropped from speech but preserved in the
    /// retained ALERTS tab, so catch-up stays intact.
    static let announcementThrottleInterval: TimeInterval = 5

    static func shouldAnnounce(now: Date, lastAnnouncement: Date?) -> Bool {
        guard let lastAnnouncement else { return true }
        return now.timeIntervalSince(lastAnnouncement) >= Self.announcementThrottleInterval
    }

    /// D-once-keyed dismisses the visible notice. Command/Control/Option
    /// combinations stay with the responder chain; Shift ("D") still dismisses
    /// since the panel has no text input to receive it.
    static func isNoticeDismissKeyPress(charactersIgnoringModifiers: String?, hasModifiers: Bool) -> Bool {
        !hasModifiers && charactersIgnoringModifiers?.lowercased() == "d"
    }
}

/// Testable transition tokens; `transition` resolves the macOS 14 `AnyTransition`.
enum NotchTransition: Equatable, Sendable {
    case identity
    case swapInsertion
    case swapRemoval
    case swap
    case consecutiveSwap
    case tabForward
    case tabBackward

    var transition: AnyTransition {
        switch self {
        case .identity:
            .identity
        case .swapInsertion:
            .opacity.combined(with: .scale(scale: 0.965))
        case .swapRemoval:
            .opacity.combined(with: .scale(scale: 0.92))
        case .swap:
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.965)),
                removal: .opacity.combined(with: .scale(scale: 0.92)))
        case .consecutiveSwap:
            .opacity.combined(with: .scale)
        case .tabForward:
            .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity))
        case .tabBackward:
            .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity))
        }
    }
}

/// Injected sleep seam for the P1a collapse-completion scheduler.
protocol NotchSleeper: Sendable {
    func sleep(_ duration: Duration) async throws
}

struct LiveNotchSleeper: NotchSleeper, Sendable {
    func sleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
