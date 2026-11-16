import AppKit
import CalendarCore
import SwiftUI

extension CalendarTint {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .violet: return .purple
        case .cyan: return .cyan
        case .lime: return Color(red: 0.48, green: 0.73, blue: 0.08)
        case .yellow: return .yellow
        case .pink: return .pink
        case .gray: return .gray
        }
    }

    var title: String {
        switch self {
        case .blue: return "Синий"
        case .green: return "Зелёный"
        case .orange: return "Оранжевый"
        case .red: return "Красный"
        case .violet: return "Фиолетовый"
        case .cyan: return "Голубой"
        case .lime: return "Салатовый"
        case .yellow: return "Жёлтый"
        case .pink: return "Розовый"
        case .gray: return "Серый"
        }
    }
}

extension AppTheme {
    @MainActor static func meetingColor(_ meeting: Meeting, model: AppModel) -> Color {
        model.meetingTint(for: meeting)?.color ?? defaultCalendarColor
    }
}

extension View {
    func calendarEventCard(color: Color, selected: Bool = false, cornerRadius: CGFloat = 4) -> some View {
        modifier(CalendarEventCardStyle(color: color, selected: selected, cornerRadius: cornerRadius))
    }
}

private struct CalendarEventCardStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let color: Color
    let selected: Bool
    let cornerRadius: CGFloat

    private var fillOpacity: Double {
        let base = colorScheme == .dark ? 0.34 : 0.18
        let selection = selected ? 0.06 : 0
        return base + selection - (contrast == .increased ? 0.10 : 0)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return content
            .background {
                shape.fill(AppTheme.canvas)
                    .overlay { shape.fill(color.opacity(fillOpacity)) }
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(color).frame(width: 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .clipShape(shape)
            .overlay {
                if selected {
                    shape.strokeBorder(contrast == .increased ? Color.primary : Color.accentColor,
                                       lineWidth: contrast == .increased ? 2 : 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

struct CalendarSidebarColorButton: View {
    @ObservedObject var model: AppModel
    let calendar: CalendarInfo
    @State private var showPalette = false

    var body: some View {
        Button {
            showPalette.toggle()
        } label: {
            Circle()
                .fill(model.calendarTint(for: calendar.id)?.color ?? AppTheme.defaultCalendarColor)
                .frame(width: 10, height: 10)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Цвет календаря «\(calendar.name)»")
        .accessibilityValue(model.calendarTint(for: calendar.id)?.title ?? "По умолчанию")
        .help("Изменить цвет календаря")
        .popover(isPresented: $showPalette, arrowEdge: .trailing) {
            CalendarTintPalette(selected: model.calendarTint(for: calendar.id), resetTitle: "Цвет по умолчанию") { tint in
                model.setCalendarTint(tint, for: calendar.id)
                showPalette = false
            }
            .padding(12)
            .frame(width: 276)
        }
    }
}

struct MeetingTintButton: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @State private var showPalette = false
    @State private var scope = EventScope.occurrence

    var body: some View {
        Button {
            scope = .occurrence
            showPalette.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle().fill(AppTheme.meetingColor(meeting, model: model))
                    .frame(width: 10, height: 10)
                Image(systemName: "paintpalette")
            }
        }
        .accessibilityLabel("Цвет встречи")
        .help("Цвет встречи")
        .popover(isPresented: $showPalette) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Цвет встречи").font(.headline).accessibilityAddTraits(.isHeader)
                if meeting.isRecurring {
                    Picker("Применить цвет", selection: $scope) {
                        ForEach(EventScope.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                CalendarTintPalette(selected: model.meetingTint(for: meeting, scope: scope),
                    resetTitle: scope == .occurrence && model.meetingTint(for: meeting, scope: .series) != nil
                        ? "Цвет серии" : "Цвет календаря",
                    resetColor: inheritedColor) { tint in
                    model.setMeetingTint(tint, for: meeting, scope: scope)
                    showPalette = false
                }
            }
            .padding(14)
            .frame(width: 280)
            .background(AppTheme.calendarChrome)
        }
    }

    private var inheritedColor: Color {
        if scope == .occurrence, let seriesTint = model.meetingTint(for: meeting, scope: .series) {
            return seriesTint.color
        }
        return model.personalState(for: meeting).calendarTint(for: meeting.sourceCalendarID)?.color
            ?? AppTheme.defaultCalendarColor
    }
}

private struct CalendarTintPalette: View {
    let selected: CalendarTint?
    let resetTitle: String
    var resetColor: Color = AppTheme.defaultCalendarColor
    let select: (CalendarTint?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 5) {
                ForEach(CalendarTint.allCases, id: \.self) { tint in
                    Button {
                        select(tint)
                    } label: {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(tint.color)
                                .frame(width: 23, height: 18)
                                .overlay {
                                    if tint == selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(2)
                                            .background(.black.opacity(0.8), in: Circle())
                                    }
                                }
                                .accessibilityHidden(true)
                            Text(tint.title).font(.callout)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        .frame(minHeight: 29)
                        .background(tint == selected ? Color.primary.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tint.title)
                    .accessibilityAddTraits(tint == selected ? .isSelected : [])
                    .help(tint.title)
                }
            }
            Divider()
            Button { select(nil) } label: {
                HStack {
                    Circle().fill(resetColor).frame(width: 10, height: 10)
                    Text(resetTitle)
                    Spacer(minLength: 0)
                    if selected == nil { Image(systemName: "checkmark") }
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected == nil ? .isSelected : [])
            .disabled(selected == nil)
        }
    }
}

struct MeetingTintMenu: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting

    var body: some View {
        Menu("Цвет встречи") {
            if meeting.isRecurring {
                ForEach(EventScope.allCases, id: \.self) { scope in
                    Menu(scope.rawValue) { colors(for: scope) }
                }
            } else {
                colors(for: .occurrence)
            }
        }
    }

    @ViewBuilder private func colors(for scope: EventScope) -> some View {
        let selected = model.meetingTint(for: meeting, scope: scope)
        ForEach(CalendarTint.allCases, id: \.self) { tint in
            Button {
                model.setMeetingTint(tint, for: meeting, scope: scope)
            } label: {
                Label {
                    Text(tint.title + (tint == selected ? " ✓" : ""))
                } icon: {
                    Image(nsImage: menuSwatch(for: tint))
                        .renderingMode(.original)
                }
            }
        }
        Divider()
        Button(scope == .occurrence && model.meetingTint(for: meeting, scope: .series) != nil
            ? "Цвет серии" : "Цвет календаря") {
            model.setMeetingTint(nil, for: meeting, scope: scope)
        }
        .disabled(selected == nil)
    }

    private func menuSwatch(for tint: CalendarTint) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(tint.color).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
