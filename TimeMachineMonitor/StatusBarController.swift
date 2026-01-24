import AppKit
import SwiftUI
import Combine

class StatusBarController {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var timeMachineService: TimeMachineService
    private var notificationManager: NotificationManager
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    init(timeMachineService: TimeMachineService, notificationManager: NotificationManager) {
        self.timeMachineService = timeMachineService
        self.notificationManager = notificationManager

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()

        setupStatusItem()
        setupPopover()
        setupBindings()
        setupEventMonitor()
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            updateStatusItemImage(isBackingUp: timeMachineService.status.isBackingUp)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        let menuView = MenuView(
            timeMachineService: timeMachineService,
            notificationManager: notificationManager,
            onQuit: { [weak self] in
                self?.popover.performClose(nil)
                NSApplication.shared.terminate(nil)
            }
        )

        popover.contentViewController = NSHostingController(rootView: menuView)
        popover.behavior = .transient
        popover.animates = true
    }

    private func setupBindings() {
        timeMachineService.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateStatusItemImage(isBackingUp: status.isBackingUp)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .backupCompleted)
            .sink { [weak self] _ in
                self?.notificationManager.sendBackupCompletedNotification()
            }
            .store(in: &cancellables)
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }
    }

    private func updateStatusItemImage(isBackingUp: Bool) {
        guard let button = statusItem.button else { return }

        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let context = NSGraphicsContext.current?.cgContext

            // LED colors: Green = safe, Red = backing up
            let ledColor: NSColor = isBackingUp ? .systemRed : .systemGreen
            let glowColor = ledColor.withAlphaComponent(0.4)

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let ledRadius: CGFloat = 5
            let glowRadius: CGFloat = 7

            // Draw glow
            context?.saveGState()
            let glowPath = CGPath(ellipseIn: CGRect(
                x: center.x - glowRadius,
                y: center.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            ), transform: nil)
            context?.addPath(glowPath)
            context?.setFillColor(glowColor.cgColor)
            context?.fillPath()
            context?.restoreGState()

            // Draw main LED
            let ledPath = CGPath(ellipseIn: CGRect(
                x: center.x - ledRadius,
                y: center.y - ledRadius,
                width: ledRadius * 2,
                height: ledRadius * 2
            ), transform: nil)
            context?.addPath(ledPath)
            context?.setFillColor(ledColor.cgColor)
            context?.fillPath()

            // Draw highlight
            let highlightRadius: CGFloat = 2
            let highlightCenter = CGPoint(x: center.x - 1.5, y: center.y + 1.5)
            let highlightPath = CGPath(ellipseIn: CGRect(
                x: highlightCenter.x - highlightRadius,
                y: highlightCenter.y - highlightRadius,
                width: highlightRadius * 2,
                height: highlightRadius * 2
            ), transform: nil)
            context?.addPath(highlightPath)
            context?.setFillColor(NSColor.white.withAlphaComponent(0.4).cgColor)
            context?.fillPath()

            return true
        }

        image.isTemplate = false
        button.image = image

        // Set accessibility description
        button.toolTip = isBackingUp ? "Time Machine: Backup in progress" : "Time Machine: Safe to disconnect"
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // Defer popover show to next run loop to avoid layout recursion
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
