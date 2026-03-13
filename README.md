# Backup Bar

A lightweight macOS menu bar application that displays the current Time Machine backup status via an LED indicator, providing at-a-glance safety confirmation for disconnecting external storage.

## Features

- **LED Status Indicator**: Green (safe to disconnect) / Red (backup in progress)
- **Detailed Dropdown Menu**:
  - Current backup status and progress
  - Last backup date and time
  - Next scheduled backup estimate
  - Destination disk information
  - Storage space visualization
  - Recent backup history (last 3)
- **Manual Backup Trigger**: Start a backup with one click
- **System Notifications**: Alerts when backups complete or fail
- **Launch at Login**: Option to start automatically

## Requirements

- macOS 13.0 (Ventura) or later
- Time Machine configured with a backup destination

## Installation

1. Open `TimeMachineMonitor.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Build and run (⌘R)
4. The app will appear in your menu bar as a colored LED indicator

## Usage

- **Green LED**: No backup in progress - safe to disconnect your storage hub
- **Red LED**: Backup in progress - do NOT disconnect
- **Click the LED**: Opens dropdown with detailed backup information
- **Back Up Now**: Manually trigger a Time Machine backup
- **Preferences**: Toggle launch at login and notifications

## Architecture

```
TimeMachineMonitor/
├── TimeMachineMonitorApp.swift    # App entry point and delegate
├── StatusBarController.swift       # Menu bar item management
├── TimeMachineService.swift        # tmutil interface and status polling
├── MenuView.swift                  # SwiftUI dropdown menu
├── LEDIndicator.swift              # LED visual component
├── NotificationManager.swift       # System notification handling
├── LaunchAtLogin.swift             # Login item management
└── Assets.xcassets                 # App icons and colors
```

## Technical Details

- Built with SwiftUI and AppKit
- Uses `tmutil` command-line tool for Time Machine status
- Polls every 5 seconds for status updates
- LSUIElement app (no dock icon)
- Sandboxing disabled to allow `tmutil` access

## License

MIT License
