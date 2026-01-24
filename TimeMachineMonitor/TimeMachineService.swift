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
    var lastBackupDate: Date? = nil
    var nextBackupDate: Date? = nil
    var destinationName: String = "Unknown"
    var destinationPath: String = ""
    var backupSizeUsed: Int64? = nil
    var diskSpaceAvailable: Int64? = nil
    var diskSpaceTotal: Int64? = nil
    var recentBackups: [BackupInfo] = []
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
            } else if let firstDestination = destinations.first {
                newStatus.destinationName = firstDestination.name
            }
        }

        // Get disk space info
        if !newStatus.destinationPath.isEmpty {
            if let spaceInfo = getDiskSpace(path: newStatus.destinationPath) {
                newStatus.diskSpaceAvailable = spaceInfo.available
                newStatus.diskSpaceTotal = spaceInfo.total
            }
        }

        // Try to get backup info - attempt tmutil first, fall back to other methods
        var gotBackupInfo = false

        // Try tmutil commands (require FDA but let's try anyway and check the output)
        if let latestOutput = runCommand("/usr/bin/tmutil", arguments: ["latestbackup"]) {
            let path = latestOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            // Check if we got valid output (not an error message)
            if !path.isEmpty &&
               !path.contains("No backups") &&
               !path.contains("requires Full Disk Access") &&
               !path.contains("error") &&
               path.hasPrefix("/") {
                if let date = extractDateFromBackupPath(path) {
                    newStatus.lastBackupDate = date
                    gotBackupInfo = true
                } else {
                }
            }
        }

        if let listOutput = runCommand("/usr/bin/tmutil", arguments: ["listbackups"]) {
            // Only process if we didn't get an error about FDA
            if !listOutput.contains("requires Full Disk Access") {
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
                    gotBackupInfo = true
                }
            }
        }

        // Always try local snapshots as additional source (they don't require FDA)
        if let localSnapshots = getLocalSnapshots(), !localSnapshots.isEmpty {
            // If we don't have backup info yet, use local snapshots
            if !gotBackupInfo || newStatus.lastBackupDate == nil {
                newStatus.lastBackupDate = localSnapshots.first?.timestamp
            }
            // If we don't have recent backups, use local snapshots
            if newStatus.recentBackups.isEmpty {
                newStatus.recentBackups = Array(localSnapshots.prefix(3))
            }
        }

        // Fallback: Try scanning HFS+ backup directory
        if newStatus.lastBackupDate == nil && !newStatus.destinationPath.isEmpty {
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
        // First try to get local snapshots (works for APFS without FDA)
        if let localBackups = getLocalSnapshots(), !localBackups.isEmpty {
            return (localBackups.first?.timestamp, Array(localBackups.prefix(3)))
        }

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
