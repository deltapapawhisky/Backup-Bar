import Foundation
import Combine

struct BackupInfo {
    let timestamp: Date
    let destinationName: String
}

struct TimeMachineStatus {
    var isBackingUp: Bool = false
    var backupPhase: String = ""
    var progressPercent: Double? = nil
    var lastBackupDate: Date? = nil          // Last actual backup to external disk
    var lastLocalSnapshotDate: Date? = nil   // Last local APFS snapshot
    var nextBackupDate: Date? = nil
    var destinationName: String = "Unknown"
    var destinationPath: String = ""
    var destinationConnected: Bool = false   // Whether backup disk is connected
    var backupSizeUsed: Int64? = nil
    var diskSpaceAvailable: Int64? = nil
    var diskSpaceTotal: Int64? = nil
    var recentBackups: [BackupInfo] = []     // Actual backups to external disk
    var localSnapshots: [BackupInfo] = []    // Local APFS snapshots
    var errorMessage: String? = nil
    var hasFullDiskAccess: Bool = false
}

class TimeMachineService: ObservableObject {
    @Published var status: TimeMachineStatus = TimeMachineStatus()

    private var timer: Timer?
    private var previouslyBackingUp: Bool = false
    private let pollInterval: TimeInterval = 5.0

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        updateStatus()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func checkFullDiskAccess() -> Bool {
        // Try multiple methods to detect FDA

        // Method 1: Check if we can read a protected TCC database
        let tccPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        let canReadTCC = FileManager.default.isReadableFile(atPath: tccPath)
        if canReadTCC {
            return true
        }

        // Method 2: Try running tmutil latestbackup and check if it works
        // This is the most reliable test for Time Machine FDA access
        if let output = runCommand("/usr/bin/tmutil", arguments: ["latestbackup"]) {
            // If we get output that doesn't contain "requires Full Disk Access", we have FDA
            let hasFDA = !output.contains("requires Full Disk Access") && !output.contains("error")
            if hasFDA {
                return true
            }
        }

        return false
    }

    func startBackup() {
        // Run tmutil startbackup directly - it doesn't require admin privileges
        // when Time Machine is properly configured
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
            process.arguments = ["startbackup"]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    DispatchQueue.main.async {
                        self?.status.errorMessage = "Backup failed: \(errorMessage)"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status.errorMessage = "Failed to start backup: \(error.localizedDescription)"
                }
            }
        }
    }

    func ejectBackupDisk(completion: @escaping (Bool, String?) -> Void) {
        guard status.destinationConnected, !status.destinationPath.isEmpty else {
            completion(false, "Backup disk is not connected")
            return
        }

        // Don't eject while backup is in progress
        guard !status.isBackingUp else {
            completion(false, "Cannot eject while backup is in progress")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let destinationPath = self?.status.destinationPath else {
                DispatchQueue.main.async {
                    completion(false, "Destination path not available")
                }
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["unmount", destinationPath]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        // Force an immediate status update
                        self?.updateStatus()
                        completion(true, nil)
                    } else {
                        let message = errorOutput.isEmpty ? output : errorOutput
                        completion(false, message.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    private func updateStatus() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            let newStatus = self.fetchTimeMachineStatus()

            DispatchQueue.main.async {
                let wasBackingUp = self.previouslyBackingUp
                self.previouslyBackingUp = newStatus.isBackingUp
                self.status = newStatus

                if wasBackingUp && !newStatus.isBackingUp {
                    NotificationCenter.default.post(name: .backupCompleted, object: nil)
                }
            }
        }
    }

    private func fetchTimeMachineStatus() -> TimeMachineStatus {
        var newStatus = TimeMachineStatus()

        // Check Full Disk Access status
        newStatus.hasFullDiskAccess = checkFullDiskAccess()

        // Get current backup status
        if let statusOutput = runCommand("/usr/bin/tmutil", arguments: ["status"]) {
            newStatus.isBackingUp = statusOutput.contains("Running = 1") ||
                                     statusOutput.contains("BackupPhase")

            if let phase = extractValue(from: statusOutput, key: "BackupPhase") {
                newStatus.backupPhase = phase
            }

            if let percentString = extractValue(from: statusOutput, key: "Percent"),
               let percent = Double(percentString), percent >= 0 {
                newStatus.progressPercent = percent * 100
            }
        }

        // Get destination info - parse the actual tmutil output format
        if let destOutput = runCommand("/usr/bin/tmutil", arguments: ["destinationinfo"]) {
            let destinations = parseDestinations(destOutput)
            // Use the first destination that has a mount point (meaning it's connected)
            if let activeDestination = destinations.first(where: { $0.mountPoint != nil }) {
                newStatus.destinationName = activeDestination.name
                newStatus.destinationPath = activeDestination.mountPoint ?? ""
                newStatus.destinationConnected = true
            } else if let firstDestination = destinations.first {
                newStatus.destinationName = firstDestination.name
                newStatus.destinationConnected = false
            }
        }

        // Get disk space info
        if !newStatus.destinationPath.isEmpty {
            if let spaceInfo = getDiskSpace(path: newStatus.destinationPath) {
                newStatus.diskSpaceAvailable = spaceInfo.available
                newStatus.diskSpaceTotal = spaceInfo.total
            }
        }

        // Try to get backup info from tmutil (requires FDA and connected disk)
        if let latestOutput = runCommand("/usr/bin/tmutil", arguments: ["latestbackup"]) {
            let path = latestOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            // Check if we got valid output (not an error message)
            if !path.isEmpty &&
               !path.contains("No backups") &&
               !path.contains("requires Full Disk Access") &&
               !path.contains("error") &&
               !path.contains("Failed to mount") &&
               path.hasPrefix("/") {
                if let date = extractDateFromBackupPath(path) {
                    newStatus.lastBackupDate = date
                }
            }
        }

        if let listOutput = runCommand("/usr/bin/tmutil", arguments: ["listbackups"]) {
            // Only process if we didn't get an error about FDA or mount failure
            if !listOutput.contains("requires Full Disk Access") &&
               !listOutput.contains("Failed to mount") &&
               !listOutput.contains("No machine directory") {
                let backups = listOutput.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty && !$0.contains("error") && $0.hasPrefix("/") }
                    .suffix(3)
                    .compactMap { path -> BackupInfo? in
                        guard let date = extractDateFromBackupPath(path) else {
                            return nil
                        }
                        let destName = extractDestinationFromPath(path)
                        return BackupInfo(timestamp: date, destinationName: destName)
                    }
                if !backups.isEmpty {
                    newStatus.recentBackups = Array(backups.reversed())
                }
            }
        }

        // If disk not connected, try to get cached backup dates from Time Machine preferences
        if newStatus.lastBackupDate == nil {
            if let cachedInfo = getCachedBackupInfo(destinationName: newStatus.destinationName) {
                newStatus.lastBackupDate = cachedInfo.lastBackup
                if newStatus.recentBackups.isEmpty {
                    newStatus.recentBackups = cachedInfo.recentBackups
                }
            }
        }

        // Get local snapshots (they don't require FDA) - store separately
        if let localSnapshots = getLocalSnapshots(), !localSnapshots.isEmpty {
            newStatus.localSnapshots = Array(localSnapshots.prefix(3))
            newStatus.lastLocalSnapshotDate = localSnapshots.first?.timestamp
        }

        // Fallback: Try scanning HFS+ backup directory (only if disk is connected)
        if newStatus.lastBackupDate == nil && !newStatus.destinationPath.isEmpty && newStatus.destinationConnected {
            let backupInfo = findBackupsOnVolume(newStatus.destinationPath)
            newStatus.lastBackupDate = backupInfo.lastBackup
            newStatus.recentBackups = backupInfo.recentBackups
        }

        // Calculate next backup (Time Machine typically runs hourly)
        if let lastBackup = newStatus.lastBackupDate {
            newStatus.nextBackupDate = Calendar.current.date(byAdding: .hour, value: 1, to: lastBackup)
        }


        return newStatus
    }

    private struct DestinationInfo {
        var name: String = "Unknown"
        var mountPoint: String?
        var kind: String = ""
        var id: String = ""
    }

    private func parseDestinations(_ output: String) -> [DestinationInfo] {
        var destinations: [DestinationInfo] = []
        var currentDestination: DestinationInfo?

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check for separator lines: "===..." or "> ===..."
            // The ">" prefix indicates the default/active destination
            if trimmed.contains("====") {
                if let dest = currentDestination {
                    destinations.append(dest)
                }
                currentDestination = DestinationInfo()
                continue
            }

            guard var dest = currentDestination else { continue }

            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                switch key {
                case "Name":
                    dest.name = value
                case "Mount Point":
                    dest.mountPoint = value
                case "Kind":
                    dest.kind = value
                case "ID":
                    dest.id = value
                default:
                    break
                }
                currentDestination = dest
            }
        }

        if let dest = currentDestination {
            destinations.append(dest)
        }

        return destinations
    }

    private func findBackupsOnVolume(_ volumePath: String) -> (lastBackup: Date?, recentBackups: [BackupInfo]) {
        // Try HFS+ style Backups.backupdb directory
        let backupDBPath = (volumePath as NSString).appendingPathComponent("Backups.backupdb")

        guard FileManager.default.fileExists(atPath: backupDBPath) else {
            return (nil, [])
        }

        do {
            // List machine folders in Backups.backupdb
            let machineNames = try FileManager.default.contentsOfDirectory(atPath: backupDBPath)

            for machineName in machineNames {
                // Skip .DS_Store and other hidden files
                if machineName.hasPrefix(".") { continue }

                let machinePath = (backupDBPath as NSString).appendingPathComponent(machineName)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: machinePath, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }

                // List backup snapshots (date folders)
                let backupFolders = try FileManager.default.contentsOfDirectory(atPath: machinePath)
                    .filter { !$0.hasPrefix(".") && $0.count >= 10 } // Date format: yyyy-MM-dd-HHmmss
                    .sorted()
                    .reversed()

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"

                var backups: [BackupInfo] = []
                for folder in backupFolders.prefix(5) {
                    if let date = dateFormatter.date(from: folder) {
                        backups.append(BackupInfo(timestamp: date, destinationName: machineName))
                    }
                }

                if !backups.isEmpty {
                    return (backups.first?.timestamp, Array(backups.prefix(3)))
                }
            }
        } catch {
            // Fall back to trying tmutil (may fail without FDA)
        }

        return (nil, [])
    }

    private func getCachedBackupInfo(destinationName: String) -> (lastBackup: Date?, recentBackups: [BackupInfo])? {
        // Read Time Machine preferences to get cached backup dates
        // This works even when the backup disk is not connected
        // Use defaults command since UserDefaults can't read system-level prefs reliably
        guard let output = runCommand("/usr/bin/defaults", arguments: ["read", "/Library/Preferences/com.apple.TimeMachine"]) else {
            return nil
        }

        // Parse the plist-style output to find SnapshotDates for our destination
        // The format is nested, so we need to track when we're in the right destination block
        let lines = output.components(separatedBy: .newlines)
        var snapshotDates: [Date] = []
        var inSnapshotDates = false
        var foundTargetDestination = false
        var braceDepth = 0
        var destinationStartDepth = 0

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track brace depth to know when we exit a destination block
            if trimmed.contains("{") {
                braceDepth += 1
            }
            if trimmed.contains("}") {
                // If we're exiting our target destination block, stop
                if foundTargetDestination && braceDepth <= destinationStartDepth {
                    break
                }
                braceDepth -= 1
            }

            // Check if this line identifies our target destination
            if trimmed.contains("LastKnownVolumeName") && trimmed.contains("\"\(destinationName)\"") {
                foundTargetDestination = true
                destinationStartDepth = braceDepth
            }

            // If we found our destination, look for SnapshotDates
            if foundTargetDestination {
                if trimmed.contains("SnapshotDates") && trimmed.contains("(") {
                    inSnapshotDates = true
                    continue
                }

                if inSnapshotDates {
                    // End of SnapshotDates array
                    if trimmed.hasPrefix(")") {
                        inSnapshotDates = false
                        continue
                    }

                    // Parse date string like "2026-01-25 15:28:39 +0000"
                    let dateString = trimmed
                        .replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: ",", with: "")
                        .trimmingCharacters(in: .whitespaces)

                    if !dateString.isEmpty, let date = dateFormatter.date(from: dateString) {
                        snapshotDates.append(date)
                    }
                }
            }
        }

        if snapshotDates.isEmpty {
            return nil
        }

        let sortedDates = snapshotDates.sorted(by: >)
        let lastBackup = sortedDates.first

        let recentBackups = sortedDates.prefix(3).map { date in
            BackupInfo(timestamp: date, destinationName: destinationName)
        }

        return (lastBackup, Array(recentBackups))
    }

    private func getLocalSnapshots() -> [BackupInfo]? {
        // Use tmutil listlocalsnapshots to get APFS local snapshots
        // This doesn't require FDA
        guard let output = runCommand("/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"]) else {
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"

        var backups: [BackupInfo] = []

        for line in output.components(separatedBy: .newlines) {
            // Format: com.apple.TimeMachine.2024-01-15-123456.local
            // Split by ".": [com, apple, TimeMachine, 2024-01-15-123456, local]
            if line.contains("com.apple.TimeMachine.") {
                // Extract the date portion
                let components = line.components(separatedBy: ".")
                if components.count >= 4 {
                    let datePart = components[3] // e.g., "2024-01-15-123456"
                    if let date = dateFormatter.date(from: datePart) {
                        backups.append(BackupInfo(timestamp: date, destinationName: "Local Snapshot"))
                    }
                }
            }
        }

        // Sort by date descending
        backups.sort { $0.timestamp > $1.timestamp }
        return backups.isEmpty ? nil : backups
    }

    private func runCommand(_ command: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func extractValue(from text: String, key: String) -> String? {
        let pattern = "\(key)\\s*=\\s*\"?([^\"\\n;]+)\"?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private func extractLine(from text: String, containing keyword: String) -> String? {
        return text.components(separatedBy: .newlines)
            .first { $0.contains(keyword) }
    }

    private func extractDateFromBackupPath(_ path: String) -> Date? {
        // Backup paths typically end with: /Backups.backupdb/MachineName/2024-01-15-123456
        let components = path.components(separatedBy: "/")
        guard let lastComponent = components.last else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"

        return dateFormatter.date(from: lastComponent)
    }

    private func extractDestinationFromPath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
        if components.count >= 3 {
            return components[2]
        }
        return "Unknown"
    }

    private func getDiskSpace(path: String) -> (available: Int64, total: Int64)? {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
            guard let available = attrs[.systemFreeSize] as? Int64,
                  let total = attrs[.systemSize] as? Int64 else {
                return nil
            }
            return (available, total)
        } catch {
            return nil
        }
    }
}

extension Notification.Name {
    static let backupCompleted = Notification.Name("backupCompleted")
    static let backupFailed = Notification.Name("backupFailed")
}
