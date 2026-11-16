import AppKit
import SwiftUI
import CalendarCore
import OSLog

private let windowLogger = Logger(subsystem: CalendarBarIdentity.identifier, category: "Windowing")

enum AppWindowSize {
    static let calendar = NSSize(width: 860, height: 600)
    static let settings = NSSize(width: 720, height: 550)
    static let meeting = NSSize(width: 520, height: 500)
    static let activity = NSSize(width: 520, height: 500)
    static let pinned = NSSize(width: 440, height: 380)
}

/// One reusable window per task, including launches from notification actions.
@MainActor enum AppWindows {
    private static var controllers: [String: AppWindowController] = [:]
    static func showCalendar() {
        show("calendar", title: "CalendarBar", size: NSSize(width: 1240, height: 780), minimum: AppWindowSize.calendar) {
            AnyView(CalendarWindow(model: AppModel.shared))
        }
    }
    static func showSettings() {
        show("settings", title: "Настройки CalendarBar", size: NSSize(width: 800, height: 635), minimum: AppWindowSize.settings) {
            AnyView(SettingsView(model: AppModel.shared))
        }
    }
    static func showDemoAgenda() {
        guard CalendarBarIdentity.isDemo else { return }
        let size = NSSize(width: 354, height: 380)
        show("demo-agenda", title: "Меню CalendarBar", size: size, minimum: size) {
            AnyView(AgendaView(model: AppModel.shared)
                .tint(AppTheme.controlAccent)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(AppTheme.graphite))
        }
    }
    static func showMeeting(_ meeting: Meeting) {
        AppModel.shared.showStandaloneMeeting(meeting)
        show("meeting", title: "Встреча", size: NSSize(width: 600, height: 650), minimum: AppWindowSize.meeting) {
            AnyView(StandaloneMeetingView(model: AppModel.shared))
        }
    }
    static func showActivity() {
        show("activity", title: "Изменения и напоминания", size: NSSize(width: 600, height: 620), minimum: AppWindowSize.activity) {
            AnyView(ActivityView(model: AppModel.shared))
        }
    }
    static func showPinnedMeetings() {
        show("pinned", title: "Закреплённые встречи", size: NSSize(width: 520, height: 490), minimum: AppWindowSize.pinned) {
            AnyView(PinnedMeetingsView(model: AppModel.shared))
        }
    }
    private static func show(_ id: String, title: String, size: NSSize, minimum: NSSize, content: () -> AnyView) {
        if controllers[id] == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = title; window.isReleasedWhenClosed = false
            // A hosting controller installed directly on the window updates its
            // size limits on layout. Keep it inside an AppKit content controller.
            let container = NSViewController()
            container.view = NSView()
            let host = NSHostingController(rootView: content())
            host.sizingOptions = []
            container.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
            ])
            window.contentViewController = container
            // Restore the frame before fitting it to the current screen.
            window.center()
            let name = "CalendarBar." + id
            window.setFrameAutosaveName(name)
            _ = window.setFrameUsingName(name)
            let controller = AppWindowController(window: window, identifier: id); window.delegate = controller
            controllers[id] = controller
        }
        if let window = controllers[id]?.window { fit(window, minimum: minimum) }
        NSApp.setActivationPolicy(.regular)
        controllers[id]?.showWindow(nil); controllers[id]?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowLogger.info("Opened window \(id, privacy: .public)")
    }

    private static func fit(_ window: NSWindow, minimum: NSSize) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            window.contentMinSize = minimum
            return
        }
        let titleHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let content = window.contentRect(forFrameRect: window.frame).size
        let availableHeight = max(1, visible.height - titleHeight)
        let width = min(max(content.width, minimum.width), visible.width)
        let height = min(max(content.height, minimum.height), availableHeight)
        window.contentMinSize = NSSize(width: min(minimum.width, visible.width), height: min(minimum.height, availableHeight))
        window.setContentSize(NSSize(width: width, height: height))
        var frame = window.frame
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        window.setFrame(frame, display: false)
    }
}

private final class AppWindowController: NSWindowController, NSWindowDelegate {
    private let identifier: String

    init(window: NSWindow, identifier: String) {
        self.identifier = identifier
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    func windowWillClose(_ notification: Notification) {
        windowLogger.info("Closed window \(self.identifier, privacy: .public)")
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
