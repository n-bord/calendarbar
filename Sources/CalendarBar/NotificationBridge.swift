import Foundation
import UserNotifications
import CalendarCore

enum NotificationBridge {
    private static let unavailable = "Служба уведомлений macOS не ответила. Встречи продолжают загружаться. Проверьте разрешение в Системных настройках → Уведомления → CalendarBar."
    static let denied = "macOS запрещает уведомления CalendarBar. Откройте Системные настройки → Уведомления → CalendarBar и включите «Допуск уведомлений»."

    static func message(for error: Error) -> String {
        let error = error as NSError
        if error.domain == UNErrorDomain && error.code == UNError.Code.notificationsNotAllowed.rawValue {
            return denied + " Если CalendarBar отсутствует в списке, завершите приложение, перенесите CalendarBar.app в «Программы» и запустите оттуда через Finder."
        }
        return "Не удалось выполнить операцию с уведомлениями: " + error.localizedDescription
    }

    static func settings(_ center: UNUserNotificationCenter) async throws -> UNNotificationSettings {
        try await CallbackDeadline.wait(seconds: 5, message: unavailable) { finish in
            center.getNotificationSettings { finish(.success($0)) }
        }
    }
    static func authorize(_ center: UNUserNotificationCenter) async throws -> Bool {
        try await CallbackDeadline.wait(seconds: 20, message: unavailable) { finish in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { allowed, error in
                if let error { finish(.failure(error)) } else { finish(.success(allowed)) }
            }
        }
    }
    static func pending(_ center: UNUserNotificationCenter) async throws -> [UNNotificationRequest] {
        try await CallbackDeadline.wait(seconds: 5, message: unavailable) { finish in
            center.getPendingNotificationRequests { finish(.success($0)) }
        }
    }
    static func delivered(_ center: UNUserNotificationCenter) async throws -> [UNNotification] {
        try await CallbackDeadline.wait(seconds: 5, message: unavailable) { finish in
            center.getDeliveredNotifications { finish(.success($0)) }
        }
    }
    static func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) async throws {
        let _: Bool = try await CallbackDeadline.wait(seconds: 5, message: unavailable) { finish in
            center.add(request) { error in
                if let error { finish(.failure(error)) } else { finish(.success(true)) }
            }
        }
    }
}
