import AppKit
import SwiftUI

enum CalendarViewPreferences {
    static let compactHoursKey = "calendarHideEmptyNonWorkHours"
    static let compactHoursDefault = true
    static let compactHoursTitle = "Скрывать пустые часы вне рабочего времени"
}

enum CalendarAppearance: String, CaseIterable {
    static let storageKey = "calendarAppearance"
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "Системная"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
