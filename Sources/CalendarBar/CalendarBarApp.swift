import AppKit
import SwiftUI
import UserNotifications
import CalendarCore

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        // Copies launched from dist and Applications must not independently ask
        // Keychain for the same account. Keep the earliest running process.
        let current = NSRunningApplication.current
        let bundleID = CalendarBarIdentity.identifier
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        if !running.contains(where: { $0.processIdentifier == current.processIdentifier }) { running.append(current) }
        let first = running.min {
            let a = $0.launchDate ?? .distantPast, b = $1.launchDate ?? .distantPast
            return a == b ? $0.processIdentifier < $1.processIdentifier : a < b
        }
        if let first, first.processIdentifier != current.processIdentifier {
            first.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        if CalendarBarIdentity.isDemo {
            UserDefaults.standard.register(defaults: [CalendarAppearance.storageKey: CalendarAppearance.dark.rawValue])
        }
        let appearance = UserDefaults.standard.string(forKey: CalendarAppearance.storageKey)
            .flatMap(CalendarAppearance.init(rawValue:)) ?? .system
        appearance.apply()
        if CalendarBarIdentity.isDemo {
            let model = AppModel.shared
            model.start()
            switch ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--demo-window=") }) {
            case "--demo-window=menu": AppWindows.showDemoAgenda()
            case "--demo-window=settings": AppWindows.showSettings()
            default: AppWindows.showCalendar()
            }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let join = UNNotificationAction(identifier: "JOIN", title: "Подключиться", options: [.foreground])
        let later = UNNotificationAction(identifier: "SNOOZE5", title: "Через 5 минут", options: [])
        let start = UNNotificationAction(identifier: "AT_START", title: "В начале встречи", options: [])
        let mute = UNNotificationAction(identifier: "MUTE", title: "Больше не напоминать", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "MEETING", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "REMINDER_JOIN", actions: [join, later, start, mute], intentIdentifiers: []),
            UNNotificationCategory(identifier: "REMINDER", actions: [later, start, mute], intentIdentifiers: []),
            UNNotificationCategory(identifier: "OVERVIEW", actions: [], intentIdentifiers: [])
        ])
        AppModel.shared.start()
        if AppModel.shared.accounts.isEmpty { AppWindows.showSettings() }
    }
    @MainActor func applicationDidBecomeActive(_ notification: Notification) {
        Task { await AppModel.shared.resumeNotifications() }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            await AppModel.shared.handleNotification(response)
            completionHandler()
        }
    }
}

@main
@MainActor
struct CalendarBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @AppStorage(CalendarAppearance.storageKey) private var appearance = CalendarAppearance.system
    var body: some Scene {
        MenuBarExtra {
            AgendaView(model: model)
                .tint(AppTheme.controlAccent)
                .preferredColorScheme(appearance.colorScheme)
        } label: {
            let status = model.menuLabel(at: model.menuTime)
            Image(systemName: "calendar.badge.clock")
            if !status.isEmpty { Text(status) }
        }.menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { AppWindows.showSettings() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Календарь") {
                Button("Открыть календарь") { AppWindows.showCalendar() }
                Button("Закреплённые встречи…") { AppWindows.showPinnedMeetings() }
                Button("Изменения и напоминания") { AppWindows.showActivity() }
            }
            if CalendarBarIdentity.isDemo {
                CommandMenu("Демо") {
                    Button("Меню панели") { AppWindows.showDemoAgenda() }
                        .keyboardShortcut("1", modifiers: [.command, .shift])
                    Button("Календарь") { AppWindows.showCalendar() }
                        .keyboardShortcut("2", modifiers: [.command, .shift])
                    Button("Настройки") { AppWindows.showSettings() }
                        .keyboardShortcut("3", modifiers: [.command, .shift])
                }
            }
        }


    }
}
