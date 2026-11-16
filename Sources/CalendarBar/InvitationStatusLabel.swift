import SwiftUI
import CalendarCore

extension MeetingInvitationStatus {
    var title: String {
        switch self {
        case .accepted: return "Принято"
        case .needsAction: return "Ждёт ответа"
        case .tentative: return "Под вопросом"
        case .declined: return "Отклонено"
        case .organizer: return "Вы организатор"
        case .unknown: return "Ответ не указан"
        }
    }

    fileprivate var icon: String {
        switch self {
        case .accepted: return "checkmark.circle.fill"
        case .needsAction: return "clock"
        case .tentative: return "questionmark.circle"
        case .declined: return "xmark.circle"
        case .organizer: return "person.crop.circle"
        case .unknown: return "circle.dashed"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .accepted: return .green
        case .needsAction, .tentative: return .orange
        case .declined, .organizer, .unknown: return .secondary
        }
    }
}

struct InvitationStatusLabel: View {
    let status: MeetingInvitationStatus
    var iconOnly = false
    var showUnknown = false

    var body: some View {
        if iconOnly {
            if status != .unknown && status != .organizer {
                Image(systemName: status.icon).foregroundStyle(status.color).accessibilityHidden(true)
            }
        } else if status != .unknown || showUnknown {
            Label(status.title, systemImage: status.icon).foregroundStyle(status.color)
                .font(.caption)
        }
    }
}
