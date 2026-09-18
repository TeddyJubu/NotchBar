import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

struct NotchUsageTests {
    @Test(arguments: [
        ("codex", "com.openai.codex"),
        ("claude", "com.anthropic.claudefordesktop"),
        ("cursor", "com.todesktop.230313mzl4w4u92"),
        ("antigravity", "com.google.antigravity"),
        ("windsurf", "com.exafunction.windsurf"),
    ])
    func `desktop provider dims after quit and restores on launch`(id: String, bundleID: String) {
        let provider = NotchUsageProvider(id: id, name: id, windows: [], updatedAt: nil, error: nil)
        #expect(provider.appIsRunning(in: [bundleID]))
        #expect(!provider.appIsRunning(in: []))
        #expect(!provider.appIsRunning(in: [bundleID + ".helper"]))
        #expect(provider.appIsRunning(in: [bundleID]))
    }

    @Test
    func `providers without a desktop app retain their appearance`() {
        let provider = NotchUsageProvider(id: "gemini", name: "Gemini", windows: [], updatedAt: nil, error: nil)
        #expect(provider.appIsRunning(in: []))
    }

    @Test(arguments: [CGPoint.zero, CGPoint(x: -1512, y: 200), CGPoint(x: 350, y: 982)])
    func `panel stays below the screen top and follows the notch on offset displays`(origin: CGPoint) throws {
        let screen = CGRect(origin: origin, size: CGSize(width: 1512, height: 982))
        let geometry = try #require(NotchGeometry(
            screenFrame: screen,
            safeAreaTop: 32,
            leftArea: CGRect(x: screen.minX, y: screen.maxY - 32, width: 656, height: 32),
            rightArea: CGRect(x: screen.minX + 856, y: screen.maxY - 32, width: 656, height: 32)))

        #expect(geometry.notchWidth == 200)
        #expect(geometry.compactSize.width == 210)
        #expect(geometry.compactSize.height == geometry.closedHeight + 20)
        for expanded in [false, true] {
            let frame = geometry.frame(expanded: expanded)
            #expect(frame.midX == screen.midX)
            #expect(frame.maxY == screen.maxY)
            #expect(screen.contains(frame))
        }
        #expect(geometry.expandedSize.height > geometry.compactSize.height)
    }

    @Test
    func `panel aligns with the reported camera gap rather than assuming a centered notch`() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: CGRect(x: -1512, y: 200, width: 1512, height: 982),
            safeAreaTop: 32,
            leftArea: CGRect(x: -1512, y: 1150, width: 600, height: 32),
            rightArea: CGRect(x: -712, y: 1150, width: 712, height: 32)))
        #expect(geometry.frame(expanded: false).midX == -812)
        #expect(geometry.frame(expanded: true).midX == -812)
    }

    @Test
    func `missing notch geometry never creates an overlay`() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 950, width: 656, height: 32)
        let right = CGRect(x: 856, y: 950, width: 656, height: 32)
        #expect(NotchGeometry(screenFrame: screen, safeAreaTop: 0, leftArea: left, rightArea: right) == nil)
        #expect(NotchGeometry(screenFrame: screen, safeAreaTop: 32, leftArea: nil, rightArea: right) == nil)
        #expect(NotchGeometry(screenFrame: screen, safeAreaTop: 32, leftArea: left, rightArea: nil) == nil)
        #expect(NotchGeometry(screenFrame: screen, safeAreaTop: 32, leftArea: right, rightArea: left) == nil)
    }

    @Test
    func `provider selection falls back when the selected provider is disabled`() {
        let codex = NotchUsageProvider(id: "codex", name: "Codex", windows: [], updatedAt: nil, error: nil)
        let claude = NotchUsageProvider(id: "claude", name: "Claude", windows: [], updatedAt: nil, error: nil)
        var presentation = NotchUsagePresentation(providers: [codex, claude], selectedID: "claude")
        #expect(presentation.selected?.id == "claude")
        presentation.providers = [codex]
        #expect(presentation.selected?.id == "codex")
        presentation.providers = []
        #expect(presentation.selected == nil)
    }

    @Test
    func `compact row keeps three providers in configured order independently of details selection`() {
        let providers = (1...4).map {
            NotchUsageProvider(id: "provider-\($0)", name: "Provider \($0)", windows: [], updatedAt: nil, error: nil)
        }
        var presentation = NotchUsagePresentation(providers: providers, selectedID: "provider-4")
        #expect(presentation.compactProviders.map(\.id) == ["provider-1", "provider-2", "provider-3"])
        presentation.providers = Array(providers.prefix(1))
        #expect(presentation.compactProviders.count == 1)
        presentation.providers = []
        #expect(presentation.compactProviders.isEmpty)
    }

    @Test
    func `coding-agent notifications queue for ten seconds then retain unread alerts`() {
        let start = Date(timeIntervalSince1970: 1000)
        let first = NotchCodingAgentNotification(
            id: UUID(), provider: "Codex", title: "Task finished", message: "Done", createdAt: start)
        let second = NotchCodingAgentNotification(
            id: UUID(), provider: "Claude Code", title: "Needs input", message: "Approve", createdAt: start)
        var queue = NotchNotificationQueue()

        queue.enqueue(first, now: start)
        queue.enqueue(second, now: start)
        #expect(queue.active == first)
        #expect(queue.pending == [second])
        queue.advance(now: start.addingTimeInterval(9.99))
        #expect(queue.active == first)
        #expect(queue.unreadCount == 0)

        queue.advance(now: start.addingTimeInterval(10))
        #expect(queue.retained == [first])
        #expect(queue.unreadCount == 1)
        #expect(queue.active == second)
        #expect(queue.activeUntil == start.addingTimeInterval(20))

        queue.advance(now: start.addingTimeInterval(19.99))
        #expect(queue.retained == [first])
        queue.advance(now: start.addingTimeInterval(20))
        #expect(queue.retained == [first, second])
        #expect(queue.unreadCount == 2)
        #expect(queue.active == nil)
    }

    @Test
    func `opening retained notifications clears unread count without deleting alerts`() {
        let start = Date(timeIntervalSince1970: 2000)
        var queue = NotchNotificationQueue()
        queue.enqueue(
            NotchCodingAgentNotification(
                provider: "Cursor", title: "Task failed", message: "See terminal", createdAt: start),
            now: start)
        queue.advance(now: start.addingTimeInterval(NotchNotificationQueue.displayDuration))
        #expect(queue.unreadCount == 1)
        queue.markUnreadRead()
        #expect(queue.unreadCount == 0)
        #expect(queue.retained.count == 1)
    }

    @Test
    @MainActor
    func `notification source accepts supported hook events and ignores clears or unknown sources`() throws {
        let now = Date(timeIntervalSince1970: 3000)
        let line = Data(
            #"{"source":"claude","type":"waiting","title":"Waiting for input","message":"Approve the command","ttl":3}"#
                .utf8)
        let event = try #require(NotchAgentEventSource.notification(from: line, now: now))
        #expect(event.provider == "Claude Code")
        #expect(event.title == "Waiting for input")
        #expect(event.message == "Approve the command")
        #expect(event.createdAt == now)

        let clear = Data(#"{"source":"claude","type":"clear","title":"stale","message":"stale"}"#.utf8)
        #expect(NotchAgentEventSource.notification(from: clear, now: now) == nil)
        let unknown = Data(#"{"source":"slack","type":"completed","title":"done","message":"done"}"#.utf8)
        #expect(NotchAgentEventSource.notification(from: unknown, now: now) == nil)
        #expect(NotchAgentEventSource.notification(from: Data("not json".utf8), now: now) == nil)
    }

    @Test
    @MainActor
    func `notification source skips startup history and handles partial oversized and truncated lines`() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-events-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let existing = #"{"source":"codex","type":"completed","title":"old","message":"history"}"#
            + "\n"
            + #"{"source":"claude","type":"waiting","title":"partial","message":"old"}"#
        try Data(existing.utf8).write(to: fileURL)

        var received: [NotchCodingAgentNotification] = []
        let source = NotchAgentEventSource(fileURL: fileURL) { event in
            received.append(event)
        }
        let start = Date(timeIntervalSince1970: 5000)
        source.pollForTesting(now: start)
        #expect(received.isEmpty)

        func append(_ data: Data) throws {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }

        // Completing the old startup partial line must not replay it. A new line
        // appended after that partial data is still delivered.
        try append(Data("history-tail\n".utf8))
        source.pollForTesting(now: start.addingTimeInterval(1))
        #expect(received.isEmpty)
        try append(Data("{\"source\":\"codex\",\"type\":\"completed\",\"title\":\"new".utf8))
        source.pollForTesting(now: start.addingTimeInterval(2))
        #expect(received.isEmpty)
        try append(Data("\", \"message\":\"done\"}\n".utf8))
        source.pollForTesting(now: start.addingTimeInterval(3))
        #expect(received.map(\.title) == ["new"])
        #expect(received.first?.createdAt == start.addingTimeInterval(3))

        try append(Data((String(repeating: "x", count: 17000) + "\nnot json\n").utf8))
        source.pollForTesting(now: start.addingTimeInterval(4))
        #expect(received.count == 1)

        // A truncation resets the offset and accepts the replacement's new event.
        let replacement = #"{"source":"cursor","type":"failed","title":"replacement","message":"done"}"# + "\n"
        try Data(replacement.utf8).write(to: fileURL)
        source.pollForTesting(now: start.addingTimeInterval(5))
        #expect(received.map(\.title) == ["new", "replacement"])
    }

    @Test
    @MainActor
    func `notification source reads a new file created after launch`() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-agent-events-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var received: [NotchCodingAgentNotification] = []
        let source = NotchAgentEventSource(fileURL: fileURL) { event in
            received.append(event)
        }
        source.start()
        source.stop()

        let start = Date(timeIntervalSince1970: 6000)
        let event = #"{"source":"cursor","type":"completed","title":"first event","message":"new file"}"# + "\n"
        try Data(event.utf8).write(to: fileURL)
        source.pollForTesting(now: start)
        #expect(received.map(\.title) == ["first event"])
        #expect(received.first?.createdAt == start)
    }

    @Test
    func `notification queue starts empty and bounds pending and retained state`() {
        let start = Date(timeIntervalSince1970: 4000)
        var queue = NotchNotificationQueue()
        #expect(queue.active == nil)
        #expect(queue.retained.isEmpty)
        #expect(queue.unreadCount == 0)
        for index in 0..<(NotchNotificationQueue.maxPendingCount + 5) {
            queue.enqueue(
                NotchCodingAgentNotification(
                    provider: "Codex", title: "Alert \(index)", message: "", createdAt: start),
                now: start)
        }
        #expect(queue.pending.count == NotchNotificationQueue.maxPendingCount)
        for index in 0..<(NotchNotificationQueue.maxPendingCount + 5) {
            queue.advance(now: start.addingTimeInterval(Double(index + 1) * NotchNotificationQueue.displayDuration))
        }
        #expect(queue.retained.count <= NotchNotificationQueue.maxRetainedCount)
        #expect(queue.unreadCount <= NotchNotificationQueue.maxRetainedCount)
    }

    @Test
    func `notification geometry adds one row only while a banner is active`() throws {
        let geometry = try #require(NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32,
            leftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
            rightArea: CGRect(x: 856, y: 950, width: 656, height: 32)))
        #expect(geometry.frame(expanded: false).height == geometry.compactSize.height)
        #expect(geometry.frame(expanded: false, notificationVisible: true).height
            == geometry.notificationCompactSize.height)
        #expect(geometry.frame(expanded: true, notificationVisible: true).height
            == geometry.notificationExpandedSize.height)
    }

    @Test(arguments: [-20.0, 0, 42.5, 100, 150])
    func `usage is clamped only for display without changing source data`(used: Double) throws {
        let source = RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let window = try #require(NotchUsageWindow(source, label: "Session"))
        #expect(window.usedPercent == min(100, max(0, used)))
        #expect(source.usedPercent == used)
    }

    @Test
    func `missing synthetic and nonfinite usage never masquerades as available quota`() {
        #expect(NotchUsageWindow(nil, label: "Session") == nil)
        let placeholder = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        #expect(NotchUsageWindow(placeholder, label: "Session") == nil)
        for used in [Double.nan, .infinity, -.infinity] {
            let source = RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
            #expect(NotchUsageWindow(source, label: "Session") == nil)
        }
        let genuineReset = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        #expect(NotchUsageWindow(genuineReset, label: "Session")?.usedPercent == 0)
    }

    @Test
    @MainActor
    func `factory labels follow the reported quota shape while codex hides unsupported tertiary usage`() {
        let window = RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let modern = UsageSnapshot(primary: window, secondary: window, tertiary: window, updatedAt: .distantPast)
        let legacy = UsageSnapshot(primary: window, secondary: window, updatedAt: .distantPast)
        #expect(NotchUsageProvider.usageWindows(snapshot: modern, provider: .factory).map(\.label)
            == ["5-hour", "Weekly", "Monthly"])
        #expect(NotchUsageProvider.usageWindows(snapshot: legacy, provider: .factory).map(\.label)
            == ["Standard", "Premium"])
        #expect(NotchUsageProvider.usageWindows(snapshot: modern, provider: .codex).map(\.label)
            == ["Session", "Weekly"])
    }

    @Test
    @MainActor
    func `claude cost only account shows spend quota without inventing a session`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 5,
                limit: 20,
                currencyCode: "USD",
                period: " Monthly cap ",
                updatedAt: .distantPast),
            updatedAt: .distantPast)
        let windows = NotchUsageProvider.usageWindows(snapshot: snapshot, provider: .claude)
        #expect(windows.map(\.label) == ["Monthly cap"])
        #expect(windows.map(\.usedPercent) == [25])
    }

    @Test
    @MainActor
    func `unknown extra quota is omitted while known extra quota retains its title`() {
        let window = RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(id: "unknown", title: "Unreported", window: window, usageKnown: false),
                NamedRateWindow(id: "known", title: "Shared requests", window: window),
            ],
            updatedAt: .distantPast)
        let windows = NotchUsageProvider.usageWindows(snapshot: snapshot, provider: .codex)
        #expect(windows.map(\.label) == ["Shared requests"])
        #expect(windows.map(\.usedPercent) == [100])
    }
}
