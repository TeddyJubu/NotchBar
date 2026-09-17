# NotchBar

A lightweight macOS menu bar and MacBook notch app for tracking OpenAI Codex and Claude Code usage without needing to log in to a website.

NotchBar shows your current quota, reset windows, and usage health in a compact, glanceable interface. It is designed for developers who want to stay aware of their AI coding limits without opening a browser or signing into a dashboard.

## Why this app exists

Modern AI coding tools often hide usage behind web dashboards and credentials. NotchBar keeps the experience local and minimal:

- Watch Codex and Claude usage from the menu bar
- View usage data next to the MacBook notch when available
- See remaining quota and reset timing at a glance
- Avoid account login flows just to check usage
- Keep the app focused on status, not noise

## Features

- macOS menu bar status indicator
- MacBook notch display support
- Usage tracking for OpenAI Codex
- Usage tracking for Claude Code
- Reset countdowns and quota windows
- Minimal UI optimized for quick checks
- Local-first usage checks with no browser login required
- Privacy-conscious design that reads provider state from local sources

## Requirements

- macOS 14 or later
- Swift 6.2+
- Xcode or the Swift toolchain

## Installation

### Build from source

```bash
git clone https://github.com/TeddyJubu/NotchBar.git
cd NotchBar
swift build
./Scripts/package_app.sh debug
open CodexBar.app
```

If you are developing and want to rebuild and relaunch quickly:

```bash
./Scripts/compile_and_run.sh
```

## Usage

1. Build and launch the app.
2. Enable the provider or sources you want to monitor.
3. Let NotchBar read the local usage state for your Codex or Claude setup.
4. Check the menu bar or notch panel for current usage and reset timing.

## Privacy and data handling

NotchBar is designed to respect user privacy. It reads local provider state and stored configuration when available, and does not require a cloud login just to view usage. It does not store your account password or force browser-based authentication for basic usage tracking.

## Development

This project is built with Swift and follows the existing app structure in the repository. Common local commands include:

```bash
swift build
swift test
./Scripts/package_app.sh
./Scripts/compile_and_run.sh
```

## Project status

NotchBar is an open-source utility for local AI usage visibility. It is intentionally focused, compact, and easy to build and extend.

## License

This project is licensed under the MIT License.

Copyright (c) 2026 TeddyJubu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
