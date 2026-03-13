# Backup Bar

macOS menu bar utility that monitors Time Machine backup status. macOS 13.0+.

## Build

Open `BackupBar.xcodeproj` in Xcode, build the **BackupBar** target.

## Architecture

MVVM + Combine. Hybrid AppKit (menu bar) + SwiftUI (popover content).

```
BackupBar/
  BackupBarApp.swift             # @main entry, AppDelegate adaptor
  StatusBarController.swift      # NSStatusItem, custom LED icon, NSPopover toggle
  TimeMachineService.swift       # Core monitor — polls tmutil every 5 seconds
  MenuView.swift                 # SwiftUI popover content
  LEDIndicator.swift             # LED visual component (menu bar + popover variants)
  NotificationManager.swift      # System notifications for backup events
  LaunchAtLogin.swift            # SMAppService (macOS 13+)
  UpdateChecker.swift            # GitHub release update checking
```

## How It Works

`TimeMachineService` polls on a background queue every 5 seconds using system commands:
1. `tmutil status` — current backup state
2. `tmutil destinationinfo` — backup disk info
3. `tmutil latestbackup` — most recent backup
4. `tmutil listbackups` — recent history (last 3)
5. `tmutil listlocalsnapshots` — local APFS snapshots
6. `defaults read com.apple.TimeMachine` — cached dates when disk disconnected
7. `diskutil` — disk space info

Status published via `@Published var status: TimeMachineStatus` → Combine sink updates UI.

## Permissions

- **Full Disk Access** — strongly recommended (enables `tmutil listbackups` and reading system prefs). App degrades gracefully without it.
- **User Notifications** — requested at startup
- **Not sandboxed** — runs `tmutil`/`diskutil` via Foundation `Process`

## Notes

- LSUIElement: true (menu bar only, no dock icon)
- LED icon is custom-drawn, not an asset
- No test targets
