import SwiftUI

struct MenuView: View {
    @ObservedObject var timeMachineService: TimeMachineService
    @ObservedObject var notificationManager: NotificationManager
    var onQuit: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Full Disk Access warning if needed
            if !timeMachineService.status.hasFullDiskAccess {
                fullDiskAccessBanner

                Divider()
                    .padding(.vertical, 8)
            }

            // Status Header
            statusHeader

            Divider()
                .padding(.vertical, 8)

            // Backup Information
            backupInfoSection

            Divider()
                .padding(.vertical, 8)

            // Storage Information
            storageInfoSection

            Divider()
                .padding(.vertical, 8)

            // Recent Backups
            recentBackupsSection

            Divider()
                .padding(.vertical, 8)

            // Actions
            actionsSection

            Divider()
                .padding(.vertical, 8)

            // Preferences
            preferencesSection

            Divider()
                .padding(.vertical, 8)

            // Quit
            Button(action: onQuit) {
                HStack {
                    Text("Quit Time Machine Monitor")
                    Spacer()
                    Text("⌘Q")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .padding(.vertical, 8)
        .frame(width: 280)
    }

    private var fullDiskAccessBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Full Disk Access Required")
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            Text("Grant Full Disk Access to read backup history and start backups.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: openFullDiskAccessSettings) {
                Text("Open Privacy Settings...")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
        .padding(.horizontal, 8)
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            LEDIndicator(isBackingUp: timeMachineService.status.isBackingUp, size: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)

                if timeMachineService.status.isBackingUp {
                    if let progress = timeMachineService.status.progressPercent {
                        Text("\(Int(progress))% complete")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if !timeMachineService.status.backupPhase.isEmpty {
                        Text(formatPhase(timeMachineService.status.backupPhase))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Safe to disconnect")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var statusTitle: String {
        if timeMachineService.status.isBackingUp {
            return "Backup in Progress"
        } else {
            return "Idle"
        }
    }

    private var backupInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backup Info")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 6) {
                infoRow(label: "Destination", value: timeMachineService.status.destinationName)

                if let lastBackup = timeMachineService.status.lastBackupDate {
                    infoRow(label: "Last Backup", value: formatDate(lastBackup))
                } else {
                    infoRow(label: "Last Backup", value: "Never")
                }

                if let nextBackup = timeMachineService.status.nextBackupDate {
                    infoRow(label: "Next Backup", value: formatRelativeTime(nextBackup))
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var storageInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 6) {
                if let available = timeMachineService.status.diskSpaceAvailable,
                   let total = timeMachineService.status.diskSpaceTotal {
                    let used = total - available
                    let usedPercent = Double(used) / Double(total)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(formatBytes(available)) available")
                                .font(.caption)
                            Spacer()
                            Text("of \(formatBytes(total))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 6)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(usedPercent > 0.9 ? Color.red : Color.blue)
                                    .frame(width: geometry.size.width * usedPercent, height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                } else {
                    Text("Storage info unavailable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var recentBackupsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Backups")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            if timeMachineService.status.recentBackups.isEmpty {
                Text("No recent backups")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(timeMachineService.status.recentBackups.indices, id: \.self) { index in
                        let backup = timeMachineService.status.recentBackups[index]
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(dateFormatter.string(from: backup.timestamp))
                                .font(.caption)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                timeMachineService.startBackup()
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Back Up Now")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .disabled(timeMachineService.status.isBackingUp)

            Button(action: {
                // Open Time Machine pane directly in System Settings (macOS 13+)
                if let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Preferences-Extension") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Open Time Machine Settings...")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferences")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)

            if #available(macOS 14.0, *) {
                Toggle(isOn: $launchAtLogin) {
                    Text("Launch at Login")
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.isEnabled = newValue
                }
            } else {
                // Fallback on earlier versions
            }

            Toggle(isOn: $notificationManager.notificationsEnabled) {
                Text("Show Notifications")
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .lineLimit(1)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today, \(timeOnlyFormatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday, \(timeOnlyFormatter.string(from: date))"
        } else {
            return dateFormatter.string(from: date)
        }
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let now = Date()
        if date <= now {
            return "Soon"
        }

        let interval = date.timeIntervalSince(now)
        let minutes = Int(interval / 60)

        if minutes < 60 {
            return "in \(minutes) min"
        } else {
            let hours = minutes / 60
            let remainingMins = minutes % 60
            if remainingMins == 0 {
                return "in \(hours) hr"
            } else {
                return "in \(hours) hr \(remainingMins) min"
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatPhase(_ phase: String) -> String {
        switch phase {
        case "Starting":
            return "Starting backup..."
        case "ThinningPreBackup":
            return "Preparing..."
        case "ThinningPostBackup":
            return "Cleaning up..."
        case "Copying":
            return "Copying files..."
        case "Finishing":
            return "Finishing..."
        default:
            return phase
        }
    }
}

#Preview {
    MenuView(
        timeMachineService: TimeMachineService(),
        notificationManager: NotificationManager(),
        onQuit: {}
    )
}
