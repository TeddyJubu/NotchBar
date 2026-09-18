import CodexBarCore
import SwiftUI

struct NotchUsageView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: NotchPanelState
    let selectProvider: (String) -> Void
    let toggleExpanded: () -> Void
    let hoverChanged: (Bool) -> Void
    let openSettings: () -> Void
    let openNotifications: () -> Void
    let dismissNotification: () -> Void

    private var size: CGSize {
        self.state.geometry.frame(
            expanded: self.state.expanded,
            notificationVisible: self.state.notifications.active != nil,
            expandingNoticeVisible: self.state.notifications.active?.showsExpanded == true).size
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: self.state.geometry.closedHeight)
            HStack(spacing: 0) {
                if let marker = self.state.notifications.pendingMarker {
                    self.pendingDot(severity: marker)
                        .transition(NotchAnimation.swapTransition(reduceMotion: self.reduceMotion).transition)
                        .animation(
                            NotchAnimation.content(reduceMotion: self.reduceMotion),
                            value: self.state.notifications.pendingMarker)
                }
                if self.state.presentation.compactProviders.isEmpty {
                    Button("Set up usage", action: self.openSettings)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(self.state.presentation.compactProviders) { provider in
                        self.providerChip(provider)
                            .transition(NotchAnimation.swapTransition(reduceMotion: self.reduceMotion).transition)
                    }
                    .animation(
                        NotchAnimation.content(reduceMotion: self.reduceMotion),
                        value: self.state.presentation.compactProviders.map(\.id))
                }
                if self.state.notifications.unreadCount > 0 {
                    self.notificationBadge
                        .id(NotchAnimation.badgeID(self.state.notifications.unreadCount))
                        .transition(NotchAnimation.swapTransition(reduceMotion: self.reduceMotion).transition)
                        .animation(
                            NotchAnimation.swapInsertionAnimation(reduceMotion: self.reduceMotion),
                            value: self.state.notifications.unreadCount)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            if let notification = self.state.notifications.active {
                Group {
                    if notification.showsExpanded {
                        self.expandingNotice(notification)
                            .frame(height: NotchGeometry.expandingNoticeHeight)
                    } else {
                        self.notificationBanner(notification)
                            .frame(height: 20)
                    }
                }
                .background {
                    // Dedicated announcement-only element: the visual banner
                    // subtree is accessibility-hidden, so the announcement text
                    // exists in the AX tree exactly once, on this node.
                    Text(notification.announcementText)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(notification.announcementText)
                        .opacity(0)
                }
                .overlay(alignment: .bottom) { self.hairline }
                .id(notification.id)
                .transition(NotchAnimation.consecutiveSwap(reduceMotion: self.reduceMotion).transition)
                .animation(
                    NotchAnimation.consecutiveSwapAnimation(reduceMotion: self.reduceMotion),
                    value: notification.id)
            }
            if self.state.expanded {
                self.details
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(NotchAnimation.consecutiveSwap(reduceMotion: self.reduceMotion).transition)
                    .animation(
                        NotchAnimation.open(reduceMotion: self.reduceMotion),
                        value: self.state.expanded)
            }
        }
        .frame(width: self.size.width, height: self.size.height)
        .background {
            // Adapted from Notchly's IslandMaskView (MIT), without out-of-window cutouts.
            // Keeping the mask inside the panel avoids an invisible oversized hit region.
            Rectangle().fill(.black)
                .clipShape(.rect(
                    bottomLeadingRadius: self.state.expanded ? 24 : 10,
                    bottomTrailingRadius: self.state.expanded ? 24 : 10))
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onHover(perform: self.hoverChanged)
    }

    private func providerChip(_ provider: NotchUsageProvider) -> some View {
        let window = provider.windows.first
        let display = window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—"
        return Button {
            self.selectProvider(provider.id)
            if !self.state.expanded { self.toggleExpanded() }
        } label: {
            HStack(spacing: 4) {
                self.providerIcon(provider)
                Text(display)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(self.color(window))
                    .contentTransition(.numericText())
                    .animation(
                        NotchAnimation.content(reduceMotion: self.reduceMotion),
                        value: display)
                if provider.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8)).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .saturation(provider.isAppRunning ? 1 : 0)
            .opacity(provider.isAppRunning ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(provider.name) · \(window?.label ?? "Usage unavailable")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name), " + (window.map {
            "\($0.label), \(Int($0.usedPercent.rounded())) percent used"
        } ?? "Usage unavailable"))
        .accessibilityHint(provider.error != nil
            ? "Refresh failed; data may be outdated. Show usage details"
            : "Show usage details")
    }

    private var notificationBadge: some View {
        Button(action: self.openNotifications) {
            Text("\(self.state.notifications.unreadCount)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .frame(minWidth: 18, minHeight: 16)
                .background(Color.yellow, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show coding-agent notifications")
        .accessibilityLabel("\(self.state.notifications.unreadCount) unread coding-agent notifications")
        .accessibilityHint("Show notifications")
    }

    private func notificationBanner(_ notification: NotchCodingAgentNotification) -> some View {
        let title = notification.title + NotchAnimation.countSuffix(notification.count)
        return HStack(spacing: 5) {
            Image(systemName: "bell.fill")
                .font(.system(size: 9, weight: .bold))
                .symbolEffect(.bounce, value: self.reduceMotion ? nil : notification.id)
            MarqueeText(title: title, message: notification.message)
                .id("\(notification.id)-\(notification.count)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(.yellow)
        .accessibilityHidden(true)
    }

    /// T2 expanding notice for the critical lane: severity icon-shape + text
    /// label per the §4 table, title, message, and Details/Dismiss actions.
    /// Clickable without activation via the hosting view's acceptsFirstMouse;
    /// never moves focus programmatically.
    private func expandingNotice(_ notification: NotchCodingAgentNotification) -> some View {
        let title = notification.title + NotchAnimation.countSuffix(notification.count)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: notification.type.symbolName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .symbolEffect(.bounce, value: self.reduceMotion ? nil : notification.id)
                        .accessibilityHidden(true)
                    Text(notification.type.severityLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if !notification.message.isEmpty {
                    Text(notification.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            VStack(spacing: 4) {
                // Standard buttons: Full Keyboard Access reachable once the
                // panel is key (explicit click or Show Alerts); D/Esc then act.
                Button("Details", action: self.openNotifications)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Show alert details")
                Button("Dismiss", action: self.dismissNotification)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .accessibilityHint("Dismiss this notice")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// T-minus hairline under the banner. Ticks only while the banner exists;
    /// static under Reduce Motion. Redundant with the banner itself, so it
    /// carries no information a non-animated presentation would lose.
    @ViewBuilder
    private var hairline: some View {
        if let since = self.state.notifications.activeSince,
           let until = self.state.notifications.activeUntil
        {
            if self.reduceMotion {
                self.hairlineBar(fraction: NotchAnimation.hairlineFraction(
                    now: Date(), since: since, until: until))
            } else {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    self.hairlineBar(fraction: NotchAnimation.hairlineFraction(
                        now: context.date, since: since, until: until))
                }
            }
        }
    }

    private func hairlineBar(fraction: Double) -> some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(.yellow.opacity(0.7))
                .frame(width: proxy.size.width * fraction, height: 2)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    /// Static T0 marker for unresolved waiting/access_request items. The shape
    /// is constant; severity differs by color and, for assistive tech, label.
    private func pendingDot(severity: NotchNotificationSeverity) -> some View {
        Circle()
            .fill(severity == .critical ? .orange : .yellow)
            .frame(width: 6, height: 6)
            .padding(.trailing, 4)
            .accessibilityLabel(severity == .critical
                ? "Agent needs approval"
                : "Agent waiting for input")
    }

    private func providerIcon(_ provider: NotchUsageProvider) -> some View {
        Group {
            if let usageProvider = ProviderInstanceID(rawValue: provider.id)?.firstPartyProvider,
               let icon = ProviderBrandIcon.image(for: usageProvider)
            {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(self.state.showingNotifications ? "ALERTS" : "USAGE")
                    .font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.gray)
                Spacer()
                Button(action: self.openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Open CodexBar settings").accessibilityLabel("Open settings")
                Button(action: self.toggleExpanded) { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).help("Collapse notch").accessibilityLabel("Collapse notch")
            }
            if self.state.showingNotifications {
                self.notificationDetails
                    .transition(self.tabTransition)
            } else if let provider = self.state.presentation.selected {
                Group {
                    Menu {
                        ForEach(self.state.presentation.providers) { item in
                            Button(item.name) { self.selectProvider(item.id) }
                        }
                    } label: {
                        HStack {
                            self.providerIcon(provider)
                            Text(provider.name).font(.system(size: 21, weight: .semibold))
                            Image(systemName: "chevron.down").font(.caption)
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Select usage provider")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 15) {
                            ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                                self.usageRow(window)
                            }
                            if provider.windows.isEmpty {
                                Text("No usage limits available yet. Configure this provider in Settings.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if provider.error != nil {
                                Label(
                                    provider.windows
                                        .isEmpty ? "Refresh failed" : "Refresh failed · showing last available data",
                                    systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if let updatedAt = provider.updatedAt {
                        Text("Updated \(updatedAt.formatted(date: .omitted, time: .shortened)) · percentages used")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                }
                .transition(self.tabTransition)
            } else {
                Group {
                    Text("Your AI usage, at a glance").font(.headline)
                    Text("Enable a provider in CodexBar Settings to see usage here.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Settings", action: self.openSettings).buttonStyle(.bordered)
                }
                .transition(self.tabTransition)
            }
        }
        .animation(
            NotchAnimation.tabAnimation(reduceMotion: self.reduceMotion),
            value: self.state.showingNotifications)
    }

    /// Directional USAGE↔ALERTS transition (USAGE = 0, ALERTS = 1): navigating
    /// toward ALERTS slides forward, back toward USAGE slides back.
    private var tabTransition: AnyTransition {
        NotchAnimation.tab(forward: self.state.tabForward, reduceMotion: self.reduceMotion).transition
    }

    private var notificationDetails: some View {
        Group {
            if self.state.notifications.retained.isEmpty {
                Text("No retained coding-agent notifications.")
                    .font(.callout).foregroundStyle(.secondary)
                    .transition(self.retainedTransition)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(self.state.notifications.retained.reversed()) { notification in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notification.title).font(.callout.weight(.semibold))
                                Text([notification.provider, notification.message]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(self.retainedTransition)
                        }
                    }
                }
                .transition(self.retainedTransition)
            }
        }
        .animation(
            NotchAnimation.swapInsertionAnimation(reduceMotion: self.reduceMotion),
            value: self.state.notifications.retained.map(\.id))
    }

    /// Retained-list insert/remove motion: rows pop in and shrink out with the
    /// closed-notch swap token.
    private var retainedTransition: AnyTransition {
        NotchAnimation.swapTransition(reduceMotion: self.reduceMotion).transition
    }

    private func usageRow(_ window: NotchUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label).font(.callout)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used").font(.callout.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: window.usedPercent, total: 100).tint(self.color(window))
                .accessibilityLabel(window.label)
                .accessibilityValue("\(Int(window.usedPercent.rounded())) percent used")
            if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let description = window.resetDescription, !description.isEmpty {
                Text(description).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ window: NotchUsageWindow?) -> Color {
        guard let window else { return .gray }
        return window.usedPercent >= 90 ? .orange : .mint
    }
}

/// Single-line banner text that scrolls only when it overflows its frame.
/// Unmounts with the banner, so the ticker never runs while hidden.
private struct MarqueeText: View {
    private static let gap: CGFloat = 24
    private static let pointsPerSecond: CGFloat = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let message: String

    @State private var textWidth: CGFloat = 0
    @State private var frameWidth: CGFloat = 0
    @State private var animate = false

    private var scrolling: Bool {
        NotchAnimation.marqueeScrolls(
            textWidth: self.textWidth,
            frameWidth: self.frameWidth,
            reduceMotion: self.reduceMotion)
    }

    var body: some View {
        GeometryReader { outer in
            HStack(spacing: Self.gap) {
                self.content
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: MarqueeTextWidthKey.self,
                                value: inner.size.width)
                        }
                    }
                if self.scrolling {
                    self.content.fixedSize(horizontal: true, vertical: false)
                }
            }
            .offset(x: self.animate ? -(self.textWidth + Self.gap) : 0)
            .animation(
                .linear(duration: (self.textWidth + Self.gap) / Self.pointsPerSecond)
                    .delay(0.8)
                    .repeatForever(autoreverses: false),
                value: self.animate)
            .onPreferenceChange(MarqueeTextWidthKey.self) { self.textWidth = $0 }
            .onChange(of: outer.size.width) { self.frameWidth = $0 }
            .onChange(of: self.scrolling) { self.animate = $0 }
            .onAppear {
                self.frameWidth = outer.size.width
                self.animate = self.scrolling
            }
        }
        .clipped()
    }

    private var content: some View {
        Text(self.title).font(.system(size: 10, weight: .bold))
            + Text(self.message.isEmpty ? "" : " " + self.message)
            .font(.system(size: 10, weight: .medium))
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
