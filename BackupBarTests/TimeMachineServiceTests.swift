import XCTest

/// Stands in for tmutil and records every invocation.
private final class FakeTmutil {
    private let lock = NSLock()
    private var calls: [String] = []
    private var running = false
    private var mountPoint: String? = "/"

    func setRunning(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        running = value
    }

    func setMountPoint(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        mountPoint = value
    }

    func count(_ subcommand: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0 == subcommand }.count
    }

    func run(_ command: String, _ arguments: [String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        let subcommand = arguments.first ?? ""
        calls.append(subcommand)

        switch subcommand {
        case "status":
            return "Backup session status:\n{\n    Running = \(running ? 1 : 0);\n}\n"
        case "destinationinfo":
            let mount = mountPoint.map { "Mount Point   : \($0)\n" } ?? ""
            return "====================\nName          : NAS\nKind          : Network\n\(mount)ID            : X\n"
        case "latestbackup", "listbackups":
            return "/Volumes/NAS/Backups.backupdb/Mac/2026-01-15-123456\n"
        default:
            return ""
        }
    }
}

final class TimeMachineServiceTests: XCTestCase {
    private let tick: TimeInterval = 0.02

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition", file: file, line: line)
    }

    private func makeService(_ fake: FakeTmutil) -> TimeMachineService {
        let service = TimeMachineService(pollInterval: tick, commandRunner: fake.run)
        addTeardownBlock { service.stopMonitoring() }
        return service
    }

    /// Regression: latestbackup/listbackups open a backupd session with the destination,
    /// which caused constant activity on network backup disks when run on every poll.
    func testPollingDoesNotTouchTheBackupDestination() {
        let fake = FakeTmutil()
        let service = makeService(fake)

        waitUntil { fake.count("status") >= 20 }

        XCTAssertLessThanOrEqual(fake.count("latestbackup"), 1)
        XCTAssertLessThanOrEqual(fake.count("listbackups"), 1)
        _ = service
    }

    func testBackupCompletionRefreshesHistoryOnce() {
        let fake = FakeTmutil()
        fake.setRunning(true)
        let service = makeService(fake)
        waitUntil { service.status.isBackingUp && service.status.lastBackupDate != nil }
        let before = fake.count("latestbackup")

        fake.setRunning(false)
        waitUntil { !service.status.isBackingUp && fake.count("latestbackup") == before + 1 }

        let polls = fake.count("status")
        waitUntil { fake.count("status") >= polls + 10 }
        XCTAssertEqual(fake.count("latestbackup"), before + 1)
    }

    func testPollsKeepHistoryAndLiveStateCurrent() {
        let fake = FakeTmutil()
        let service = makeService(fake)
        waitUntil { service.status.lastBackupDate != nil }

        fake.setRunning(true)
        waitUntil { service.status.isBackingUp }

        XCTAssertNotNil(service.status.lastBackupDate)
        XCTAssertFalse(service.status.recentBackups.isEmpty)
    }

    func testRefreshOnRequestReadsHistory() {
        let fake = FakeTmutil()
        let service = makeService(fake)
        waitUntil { service.status.lastBackupDate != nil }
        let before = fake.count("listbackups")

        service.refreshBackupHistory()

        waitUntil { fake.count("listbackups") == before + 1 }
    }

    func testDiskSpaceClearsWhenDestinationDisconnects() {
        let fake = FakeTmutil()
        let service = makeService(fake)
        waitUntil { service.status.diskSpaceTotal != nil }

        fake.setMountPoint(nil)

        waitUntil { !service.status.destinationConnected && service.status.diskSpaceTotal == nil }
    }
}
