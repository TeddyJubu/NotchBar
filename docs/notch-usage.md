---
summary: "MacBook notch usage display, controls, and building this fork."
read_when:
  - Enabling or using the notch display
  - Building the notch edition locally
---

# Usage in the MacBook notch

This fork adds a native AppKit and SwiftUI usage panel around the MacBook camera notch. It reuses CodexBar's enabled providers and existing usage snapshots. The notch does not create another account connection or fetch loop.

## Controls

- Enable or disable **Settings → Menu Bar → MacBook notch → Show usage in the notch**. It is enabled by default.
- Hover below the camera or click a provider to expand the panel.
- Choose a provider in the expanded panel to see its usage windows and reset times.
- Use the chevron to collapse the panel, or the gear to open settings.

Coding-agent hooks appear in a second notch row as bright yellow text. Each
completion, failure, waiting, or access-request alert stays visible for ten
seconds; queued alerts receive their own ten-second window. When an alert
expires, its retained unread count appears at the right side of the provider
row, including while another queued alert is visible. Click the count to open
the retained alert list and clear the unread count. Alerts are kept in memory
only, and existing events are skipped when CodexBar launches.

The compact display shows up to three enabled providers beneath the camera, each with its icon and first available quota percentage. Codex, Claude, Cursor, Antigravity, and Windsurf stay colorful while their desktop app runs and dim when it quits. Launching the app restores its color, including when it runs in the background. Providers without a mapped desktop app keep their usual appearance. Providers follow their configured order; click one to open its details. Percentages mean **used**, and the expanded view identifies each window. A dash means no reported usage for that position. Missing data and synthetic placeholder windows are not shown as zero usage. The expanded panel labels refresh failures and the last update time when available.

The panel uses the screen's reported safe area and camera gap. It appears only on a display with a detected notch; a display without a notch keeps the usual CodexBar menu bar interface. Display changes reposition the panel. CodexBar's existing menu bar controls remain available.

The alert feed is the local JSONL file written by the existing Notchly agent
hook integrations at `~/Library/Application Support/Notchly/agent-events.jsonl`.
The supported sources are Claude Code, Codex, and Cursor, with completion,
failure, waiting, and access-request events. CodexBar tails newly appended
lines with bounded parsing, ignores clear and malformed records, and applies
the ten-second display duration itself. It does not poll session file ages or
read macOS notification-center history. If the hook integrations are not
installed, no coding-agent alerts are produced. Codex command hooks may need
reviewing and trusting in Codex's `/hooks` screen; start a new agent session
after changing hook configuration.

## Build this fork

Use the Xcode/Swift toolchain required by this checkout's `Package.swift`, then run from the repository root:

```bash
swift build
./Scripts/package_app.sh debug
open CodexBar.app
```

The package script creates the local app bundle. The upstream Homebrew package and upstream release downloads do not contain this fork's notch feature.

For an offline check of the new display model and geometry:

```bash
CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 swift test --filter NotchUsageTests
```

These tests do not connect accounts or read Keychain credentials. They cover screen positioning, unavailable usage, display clamping, and provider selection. Actual camera cutout alignment and mouse interaction should also be checked on a notched MacBook using the freshly built app.

For an interactive preview with synthetic data, build the debug bundle and run:

```bash
open -n CodexBar.app --args --notch-proof
```

This opens a labeled preview window and the real notch panel when a notched display is connected. It starts before account discovery or provider refreshes. Close the preview window to quit. Launch the app normally to use your configured providers.

## Credits

Notch geometry and mask design are adapted from [Notchly](https://github.com/Notchly/Notchly), under its MIT license. See [Notchly-LICENSE.txt](Notchly-LICENSE.txt). The feature uses native frameworks and adds no package dependency.
