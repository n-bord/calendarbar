import Foundation
import SwiftUI
import CalendarCore

struct WeekCalendar: View {
    @ObservedObject var model: AppModel
    let days: [Date]
    let meetings: [Meeting]
    let selectedDay: Date
    let selectedID: String?
    let account: String
    let scrollTime: Date?
    let scrollID: UUID
    var workdayHours: Range<Int>? = nil
    let freeSlots: [Date: [Range<Date>]]
    let selectDay: (Date) -> Void
    let select: (Meeting, Date) -> Void
    let create: (Date) -> Void
    let plan: (Range<Date>) -> Void
    private let hourHeight: CGFloat = 52

    private struct ScrollTarget: Equatable {
        let id: UUID
        let workdayHours: Range<Int>?
    }

    var body: some View {
        let calendar = CalendarDates.calendar
        let timeline = CalendarTimeline(days: days, meetings: meetings, workdayHours: workdayHours, calendar: calendar)
        let ticks = timeline.ticks
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("GMT" + CalendarDates.text(days[0], "ZZZZZ")).font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 48)
                ForEach(days, id: \.self) { day in
                    let isToday = calendar.isDateInToday(day)
                    let selected = calendar.isDate(day, inSameDayAs: selectedDay)
                    Button { selectDay(day) } label: {
                        VStack(spacing: 5) {
                            Text(CalendarDates.text(day, "EEE").uppercased()).font(.caption2).foregroundStyle(.secondary)
                            Text(CalendarDates.text(day, "d")).font(.title3.weight(.medium))
                                .frame(width: 31, height: 31)
                                .foregroundStyle(isToday ? AppTheme.todayDateText : Color.primary)
                                .background(isToday ? AppTheme.calendarRed : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selected ? AppTheme.controlAccent.opacity(0.15) : .clear)
                        .overlay(alignment: .bottom) {
                            if selected { Rectangle().fill(AppTheme.controlAccent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(CalendarDates.text(day, "EEEE, d MMMM yyyy"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .help("Показать сводку за " + CalendarDates.text(day, "d MMMM"))
                }
            }
            Divider()
            allDayRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(ticks.indices, id: \.self) { index in
                                let minute = ticks[index]
                                let height = index + 1 < ticks.count
                                    ? CGFloat(ticks[index + 1] - minute) / 60 * hourHeight : 14
                                Text(String(format: "%02d:%02d", minute / 60, minute % 60))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: 48, height: height, alignment: .top)
                                    .id(minute)
                            }
                        }
                        ForEach(days, id: \.self) { day in
                            DayTimeline(model: model, day: day, meetings: meetings, selectedID: selectedID,
                                account: account, hourHeight: hourHeight, timeline: timeline, ticks: ticks,
                                freeSlots: freeSlots[day] ?? [],
                                select: { select($0, day) }, create: create, plan: plan)
                        }
                    }
                }.task(id: ScrollTarget(id: scrollID, workdayHours: workdayHours)) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    let target = scrollTime.map { (calendar.component(.hour, from: $0) - 1) * 60 }
                        ?? (workdayHours == nil ? 8 * 60 : timeline.startMinute)
                    proxy.scrollTo(ticks.last(where: { $0 <= target }) ?? timeline.startMinute, anchor: .top)
                }
            }
        }
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Весь день").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 48).padding(.top, 8)
            ForEach(days, id: \.self) { day in
                let events = CalendarDates.events(meetings, on: day).filter(\.allDay)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(events) { meeting in
                            let response = meeting.invitationStatus(for: account)
                            Button { select(meeting, day) } label: {
                                HStack(spacing: 3) {
                                    InvitationStatusLabel(status: response, iconOnly: true)
                                    Text(meeting.title).lineLimit(2).strikethrough(response == .declined)
                                }.font(.system(size: 10))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(4).padding(.leading, 2)
                                    .calendarEventCard(color: AppTheme.meetingColor(meeting, model: model), selected: selectedID == meeting.id)
                            }.buttonStyle(.plain)
                                .contextMenu { MeetingTintMenu(model: model, meeting: meeting) }
                                .help(meeting.title + " · " + response.title)
                                .accessibilityLabel(meeting.title + ", весь день, " + response.title)
                        }
                    }.padding(4)
                }.frame(maxWidth: .infinity)
            }
        }.frame(height: meetings.contains(where: \.allDay) ? 78 : 28)
    }
}

private struct DayTimeline: View {
    @ObservedObject var model: AppModel
    let day: Date
    let meetings: [Meeting]
    let selectedID: String?
    let account: String
    let hourHeight: CGFloat
    let timeline: CalendarTimeline
    let ticks: [Int]
    let freeSlots: [Range<Date>]
    let select: (Meeting) -> Void
    let create: (Date) -> Void
    let plan: (Range<Date>) -> Void

    var body: some View {
        let calendar = CalendarDates.calendar
        let columnColor = calendar.isDateInToday(day) ? AppTheme.todayColumn :
            (calendar.isDateInWeekend(day) ? Color.secondary.opacity(0.035) : Color.clear)
        let placements = timeline.placements(meetings, on: day, calendar: calendar,
            minimumVisibleMinutes: 0)
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(columnColor)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2, coordinateSpace: CoordinateSpace.local).onEnded { value in
                        let minute = Double(timeline.startMinute) + Double(value.location.y / hourHeight * 60)
                        if let date = timeline.date(at: minute, on: day, calendar: calendar) {
                            create(date)
                        }
                    })
                ForEach(ticks, id: \.self) { minute in
                    Rectangle().fill(Color.secondary.opacity(0.16)).frame(height: 0.5).offset(y: y(Double(minute)))
                        .allowsHitTesting(false)
                }
                Rectangle().fill(Color.secondary.opacity(0.16)).frame(width: 0.5).allowsHitTesting(false)
                // Keep each slot in its own column-aligned layer. A single
                // TimelineView around all the buttons can lay them out as a group.
                ForEach(freeSlots, id: \.self) { slot in
                    freeSlot(slot, width: geometry.size.width, calendar: calendar)
                }
                ForEach(placements) { item in
                    event(item, width: geometry.size.width)
                }
                if calendar.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let minute = timeline.minute(of: context.date, on: day, calendar: calendar)
                        if calendar.isDate(day, inSameDayAs: context.date),
                           minute >= Double(timeline.startMinute), minute < Double(timeline.endMinute) {
                            Rectangle().fill(AppTheme.calendarRed).frame(height: 1.5).offset(y: y(minute))
                                .allowsHitTesting(false)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }.frame(maxWidth: .infinity).frame(height: CGFloat(timeline.duration) / 60 * hourHeight)
    }

    @ViewBuilder private func freeSlot(_ slot: Range<Date>, width: CGFloat, calendar: Calendar) -> some View {
        let top = max(0, y(timeline.minute(of: slot.lowerBound, on: day, calendar: calendar)))
        let bottom = min(y(Double(timeline.endMinute)), y(timeline.minute(of: slot.upperBound, on: day, calendar: calendar)))
        if bottom > top {
            let inset = min(2, (bottom - top) / 4)
            FreeSlotButton(range: slot, plan: plan)
                .frame(width: max(1, width - 6), height: bottom - top - 2 * inset)
                .position(x: width / 2, y: (top + bottom) / 2)
        }
    }

    private func event(_ item: CalendarTimeline.Placement, width: CGFloat) -> some View {
        let laneWidth = max(1, (width - 4) / CGFloat(item.columnCount))
        let top = y(item.startMinute)
        let duration = y(item.endMinute) - top
        let height = max(0, duration - min(2, duration / 4))
        let response = item.meeting.invitationStatus(for: account)
        return Button { select(item.meeting) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 3) {
                    InvitationStatusLabel(status: response, iconOnly: true)
                    Text(item.meeting.title).lineLimit(height < 28 ? 1 : 3)
                        .strikethrough(response == .declined)
                }.font(.system(size: 11, weight: .medium))
                if height > 34 {
                    Text(CalendarDates.text(item.meeting.start, "HH:mm") + "–" + CalendarDates.text(item.meeting.end, "HH:mm"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                else if laneWidth >= 64 && height >= 24 {
                    Text(CalendarDates.text(item.meeting.start, "HH:mm"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 6).padding(.trailing, 3).padding(.vertical, height < 22 ? 1 : 3)
                .calendarEventCard(color: AppTheme.meetingColor(item.meeting, model: model), selected: selectedID == item.meeting.id)
        }.buttonStyle(.plain)
            .frame(width: max(1, laneWidth - 3), height: height).clipped()
            .contextMenu { MeetingTintMenu(model: model, meeting: item.meeting) }
            .offset(x: CGFloat(item.column) * laneWidth + 2, y: top)
            .help(item.meeting.title + " · " + CalendarDates.text(item.meeting.start, "HH:mm") + "–" + CalendarDates.text(item.meeting.end, "HH:mm") + " · " + response.title)
            .accessibilityLabel(item.meeting.title + ", " + CalendarDates.text(item.meeting.start, "HH:mm") + ", " + response.title)
            .opacity(response == .declined ? 0.55 : 1)
    }

    private func y(_ minute: Double) -> CGFloat {
        CGFloat(minute - Double(timeline.startMinute)) / 60 * hourHeight
    }
}

private struct FreeSlotButton: View {
    let range: Range<Date>
    let plan: (Range<Date>) -> Void
    @State private var hovering = false
    @State private var showDetails = false

    private var summary: String {
        CalendarDates.text(range.lowerBound, "HH:mm") + "–" + CalendarDates.text(range.upperBound, "HH:mm") +
            " · свободно " + CalendarDates.duration(range.upperBound.timeIntervalSince(range.lowerBound))
    }

    var body: some View {
        Button { showDetails = true } label: {
            let shape = RoundedRectangle(cornerRadius: 5)
            shape.fill(AppTheme.controlAccent.opacity(hovering || showDetails ? 0.13 : 0.025))
                .overlay {
                    if hovering || showDetails {
                        shape.strokeBorder(AppTheme.controlAccent.opacity(0.55), lineWidth: 1)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hovering || showDetails {
                        Image(systemName: "plus").font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.controlAccent).padding(4)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(summary)
        .accessibilityLabel("Свободное окно, " + CalendarDates.text(range.lowerBound, "d MMMM") + ", " + summary)
        .accessibilityHint("Показывает подробности и кнопку планирования")
        .popover(isPresented: $showDetails, arrowEdge: .trailing) {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary).font(.callout)
                    if let event = FreeSlotPlanning.eventRange(in: range, at: context.date) {
                        Text("Новая встреча: " + CalendarDates.text(event.lowerBound, "HH:mm") + "–" +
                             CalendarDates.text(event.upperBound, "HH:mm"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Запланировать") {
                            showDetails = false
                            plan(range)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("Это окно уже прошло").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .tint(AppTheme.controlAccent)
            }
        }
    }
}

struct MonthCalendar: View {
    @ObservedObject var model: AppModel
    let days: [Date]
    let anchor: Date
    let selection: Date
    let meetings: [Meeting]
    let selectedID: String?
    let account: String
    let selectDay: (Date) -> Void
    let select: (Meeting, Date) -> Void
    let create: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["ПОНЕДЕЛЬНИК", "ВТОРНИК", "СРЕДА", "ЧЕТВЕРГ", "ПЯТНИЦА", "СУББОТА", "ВОСКРЕСЕНЬЕ"], id: \.self) {
                    Text($0).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.padding(.vertical, 10)
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    ForEach(0..<6) { row in
                        HStack(spacing: 0) {
                            ForEach(Array(days[(row * 7)..<(row * 7 + 7)]), id: \.self) { day in
                                cell(day).frame(maxWidth: .infinity).frame(height: geometry.size.height / 6)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        let events = CalendarDates.events(meetings, on: day)
        let selected = CalendarDates.calendar.isDate(day, inSameDayAs: selection)
        let inMonth = CalendarDates.calendar.isDate(day, equalTo: anchor, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 3) {
            Button { selectDay(day) } label: {
                Text(CalendarDates.text(day, "d")).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CalendarDates.calendar.isDateInToday(day) ? AppTheme.todayDateText : (inMonth ? Color.primary : Color.secondary))
                    .frame(width: 24, height: 24)
                    .background(CalendarDates.calendar.isDateInToday(day) ? AppTheme.calendarRed : .clear).clipShape(Circle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(CalendarDates.text(day, "d MMMM yyyy"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            ForEach(events.prefix(2)) { meeting in
                let response = meeting.invitationStatus(for: account)
                Button { select(meeting, day) } label: {
                    HStack(spacing: 3) {
                        InvitationStatusLabel(status: response, iconOnly: true).font(.system(size: 9))
                        if !meeting.allDay { Text(CalendarDates.text(meeting.start, "HH:mm")).font(.system(size: 8)) }
                        Text(meeting.title).font(.system(size: 10)).lineLimit(1).strikethrough(response == .declined)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 5).padding(.trailing, 3).padding(.vertical, 2)
                        .calendarEventCard(color: AppTheme.meetingColor(meeting, model: model), selected: selectedID == meeting.id, cornerRadius: 3)
                }.buttonStyle(.plain).help(meeting.title + " · " + response.title)
                    .contextMenu { MeetingTintMenu(model: model, meeting: meeting) }
                    .accessibilityLabel(meeting.title + ", " + response.title)
            }
            if events.count > 2 {
                Button("Ещё \(events.count - 2)") { selectDay(day) }.font(.system(size: 10)).buttonStyle(.borderless)
            }
            Color.clear.contentShape(Rectangle()).frame(maxHeight: .infinity)
                .onTapGesture(count: 2) { create(day) }
        }.padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? AppTheme.controlAccent.opacity(0.10) : Color.clear)
            .overlay {
                Rectangle().strokeBorder(selected ? AppTheme.controlAccent : Color.secondary.opacity(0.13),
                                         lineWidth: selected ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
            .clipped()
    }
}
