#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// Offline UI proof entered before settings, account discovery, or provider startup.
@MainActor
enum NotchUsageNativeProof {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--notch-proof") else { return false }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return true
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        private var window: NSWindow?
        private var controller: NotchUsageController?

        func applicationDidFinishLaunching(_ notification: Notification) {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 560, height: 490),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "CodexBar notch preview — synthetic data"
            window.contentView = NSHostingView(rootView: ProofView())
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            self.controller = NotchUsageController(
                providers: { NotchUsageNativeProof.sampleProviders },
                openSettings: { [weak self] in
                    self?.window?.makeKeyAndOrderFront(nil)
                },
                eventFileURL: nil)
            self.controller?.start()
            NSApp.activate(ignoringOtherApps: true)
        }

        func applicationWillTerminate(_ notification: Notification) {
            self.controller?.stop()
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }
    }

    private struct ProofView: View {
        /// Provider-specific by design: this offline fixture initially selects its synthetic Codex row.
        @State private var panelState = NotchPanelState(
            presentation: NotchUsagePresentation(
                providers: NotchUsageNativeProof.sampleProviders,
                selectedID: "codex"),
            geometry: Self.proofGeometry,
            expanded: true,
            notifications: NotchUsageNativeProof.sampleNotifications,
            showingNotifications: false)

        var body: some View {
            VStack(spacing: 20) {
                Text("NOTCH USAGE · OFFLINE PREVIEW")
                    .font(.caption).tracking(2).foregroundStyle(.secondary)
                NotchUsageView(
                    state: self.panelState,
                    selectProvider: {
                        var presentation = self.panelState.presentation
                        presentation.selectedID = $0
                        self.panelState.presentation = presentation
                    },
                    toggleExpanded: { self.panelState.expanded.toggle() },
                    hoverChanged: { _ in },
                    openSettings: {},
                    openNotifications: {
                        self.panelState.tabForward = NotchAnimation.tabForward(
                            from: self.panelState.showingNotifications,
                            to: true)
                        self.panelState.showingNotifications = true
                        self.panelState.expanded = true
                        let panelState = self.panelState
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1))
                            if panelState.expanded, panelState.showingNotifications {
                                panelState.notifications.markUnreadRead()
                            }
                        }
                    },
                    dismissNotification: {
                        self.panelState.notifications.dismissActive(now: Date())
                    })
                HStack {
                    Text("Sample values only. Click the notch to collapse or expand.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Emit controller alert") {
                        NotificationCenter.default.post(
                            name: .codexBarCodingAgentNotification,
                            object: NotchCodingAgentNotification(
                                provider: "Codex",
                                title: "Task finished",
                                message: "Synthetic controller event"))
                    }
                    .buttonStyle(.bordered)
                    Button("Emit long alert") {
                        NotificationCenter.default.post(
                            name: .codexBarCodingAgentNotification,
                            object: NotchCodingAgentNotification(
                                provider: "Codex",
                                type: .waiting,
                                title: "Waiting for approval on a very long plan title that must scroll",
                                message: "and an equally long message body that keeps scrolling with it"))
                    }
                    .buttonStyle(.bordered)
                    Button("Emit approval alert") {
                        NotificationCenter.default.post(
                            name: .codexBarCodingAgentNotification,
                            object: NotchCodingAgentNotification(
                                provider: "Claude Code",
                                type: .accessRequest,
                                title: "Needs approval",
                                message: "Claude Code is waiting for approval"))
                    }
                    .buttonStyle(.bordered)
                    Button("Advance synthetic alert") {
                        guard let activeUntil = self.panelState.notifications.activeUntil else { return }
                        self.panelState.notifications.advance(now: activeUntil)
                        self.panelState.tabForward = NotchAnimation.tabForward(
                            from: self.panelState.showingNotifications,
                            to: false)
                        self.panelState.showingNotifications = false
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(width: 560, height: 490)
            .background(Color(nsColor: .windowBackgroundColor))
        }

        private static var proofGeometry: NotchGeometry {
            guard let geometry = NotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                safeAreaTop: 32,
                leftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
                rightArea: CGRect(x: 856, y: 950, width: 656, height: 32))
            else {
                fatalError("Proof fixture geometry must be valid")
            }
            return geometry
        }
    }

    private static var sampleProviders: [NotchUsageProvider] {
        [
            // Provider-specific by design: fixed synthetic provider rows exercise provider switching offline.
            self.provider(id: "codex", name: "Codex", session: 38, weekly: 62),
            self.provider(id: "claude", name: "Claude", session: 91, weekly: 47),
            self.provider(id: "cursor", name: "Cursor", session: 24, weekly: 53),
            NotchUsageProvider(id: "empty", name: "No data example", windows: [], updatedAt: nil, error: nil),
        ]
    }

    private static var sampleNotifications: NotchNotificationQueue {
        var queue = NotchNotificationQueue()
        let now = Date()
        queue.enqueue(
            NotchCodingAgentNotification(
                provider: "Codex",
                title: "Task finished",
                message: "Codex completed a turn",
                createdAt: now),
            now: now)
        queue.enqueue(
            NotchCodingAgentNotification(
                provider: "Claude Code",
                title: "Needs input",
                message: "Claude Code is waiting for approval",
                createdAt: now),
            now: now)
        return queue
    }

    private static func provider(id: String, name: String, session: Double, weekly: Double) -> NotchUsageProvider {
        let now = Date()
        let windows = [("Session", session, 3600.0), ("Weekly", weekly, 172_800.0)]
            .compactMap { label, used, reset in
                NotchUsageWindow(RateWindow(
                    usedPercent: used,
                    windowMinutes: nil,
                    resetsAt: now.addingTimeInterval(reset),
                    resetDescription: nil), label: label)
            }
        return NotchUsageProvider(id: id, name: name, windows: windows, updatedAt: now, error: nil)
    }
}
#endif
