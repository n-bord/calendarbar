import SwiftUI
import UserNotifications
import CalendarCore

struct SettingsView: View {
    private enum Page: String, CaseIterable {
        case accounts = "Подключение"
        case notifications = "Уведомления"
        case appearance = "Вид"
        case general = "Основные"
        case cache = "Кэш календаря"

        var icon: String {
            switch self {
            case .accounts: return "person.crop.circle"
            case .notifications: return "bell"
            case .appearance: return "calendar"
            case .general: return "gearshape"
            case .cache: return "internaldrive"
            }
        }
    }

    @ObservedObject var model: AppModel
    @State private var page = Page.accounts
    @AppStorage(CalendarAppearance.storageKey) private var appearance = CalendarAppearance.system
    @AppStorage(CalendarViewPreferences.compactHoursKey)
    private var compactHours = CalendarViewPreferences.compactHoursDefault

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPane
        }
        .background(AppTheme.calendarChrome)
        .tint(AppTheme.controlAccent)
        .onChange(of: appearance) { $0.apply() }
        .onAppear { Task { await model.resumeNotifications() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Page.allCases, id: \.self) { destination in
                let selected = page == destination
                Button {
                    page = destination
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: destination.icon)
                            .frame(width: 19)
                            .foregroundStyle(selected ? AppTheme.controlAccent : Color.secondary)
                            .accessibilityHidden(true)
                        Text(destination.rawValue).fontWeight(selected ? .semibold : .regular)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 9)
                    .background(selected ? AppTheme.controlAccent.opacity(0.17) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 10)
            if let address = Bundle.main.object(forInfoDictionaryKey: "CalendarBarProjectURL") as? String,
               let url = URL(string: address) {
                Link("Проект на GitHub", destination: url)
                    .font(.caption)
                    .padding(.horizontal, 9)
            }
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("Версия " + version)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(width: 166)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page != .accounts {
                Text(page.rawValue)
                    .font(.system(size: 25, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 10)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .accounts: AccountsSettingsView(model: model)
                    case .notifications: notificationOptions
                    case .appearance: appearanceOptions
                    case .general: generalOptions
                    case .cache: CalendarCacheSettings(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, page == .accounts ? 20 : 8)
                .padding(.bottom, 24)
            }
            .id(page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.canvas)
    }

    private var notificationOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            notificationStatus
            if model.accounts.count > 1, !model.configuration.login.isEmpty {
                settingNote("Настройки напоминаний и изменений: \(model.accountName(model.configuration.login)). Чтобы изменить другой аккаунт, сделайте его основным в разделе «Подключение».")
            }
            settingsSection("Напоминания до встречи") {
                reminderRow("Первое напоминание", enabled: \.firstReminderEnabled, minutes: \.firstReminderMinutes)
                Divider()
                reminderRow("Повторное напоминание", enabled: \.secondReminderEnabled, minutes: \.secondReminderMinutes)
                settingNote("От 1 до 1440 минут. В карточке встречи можно задать личное исключение.")
            }
            settingsSection("Изменения расписания") {
                settingSwitch("Новые встречи", isOn: option(\.notifyNew))
                Divider()
                settingSwitch("Переносы, изменения и отмены", isOn: option(\.notifyChanges))
                Divider()
                settingSwitch("Изменения описания и участников", isOn: option(\.notifyMinorChanges))
                settingNote("Все обнаруженные изменения сохраняются в истории независимо от этих переключателей.")
            }
            settingsSection("Краткий обзор дня") {
                HStack(spacing: 10) {
                    Text("Уведомлять утром")
                    Spacer(minLength: 8)
                    Toggle("Уведомлять утром", isOn: option(\.dailyOverviewEnabled))
                        .toggleStyle(.switch).labelsHidden()
                    DatePicker("Время уведомления", selection: dailyOverviewTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .disabled(!model.configuration.dailyOverviewEnabled)
                }
                settingNote("По календарям с включёнными уведомлениями. Данные обновляются, пока CalendarBar запущен.")
            }
            settingNote("Фокусирование и настройки macOS влияют на показ уведомлений.")
        }
        .font(.callout)
    }

    private var notificationStatus: some View {
        let authorized = model.notificationAuthorization == .authorized || model.notificationAuthorization == .provisional
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label {
                    Text(model.notificationStatus).textSelection(.enabled)
                } icon: {
                    Image(systemName: authorized ? "checkmark.square" : "bell")
                        .foregroundStyle(authorized ? AppTheme.controlAccent : Color.secondary)
                }
                Spacer(minLength: 6)
                Button("Проверить") { Task { await model.testNotification() } }
                    .accessibilityLabel("Проверить уведомление")
            }
            Button(model.notificationPermissionButton) {
                Task { await model.notificationPermissionAction() }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.controlAccent)
        }
        .disabled(model.authorizationPending)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                .padding(.top, 3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingNote(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
    }

    private func settingSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }

    private var dailyOverviewTime: Binding<Date> {
        // The picker edits a wall-clock time. The scheduler applies the Mac's local time zone.
        Binding {
            let minutes = model.configuration.dailyOverviewHour * 60 + model.configuration.dailyOverviewMinute
            return Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
        } set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = calendar.dateComponents([.hour, .minute], from: date)
            if let hour = components.hour, let minute = components.minute {
                model.setDailyOverviewTime(hour: hour, minute: minute)
            }
        }
    }
    private var appearanceOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Тема оформления", selection: $appearance) {
                ForEach(CalendarAppearance.allCases, id: \.self) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            settingsSection("Строка меню") {
                Picker("Показывать отсчёт до встречи", selection: Binding(
                    get: { model.configuration.menuCountdownWindow }, set: { model.setMenuCountdownWindow($0) }
                )) {
                    ForEach(MenuCountdownWindow.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                settingNote("В строке меню виден отсчёт до ближайшей встречи. В самом меню доступны текущие встречи, расписание и закреплённые ссылки.")
            }
            settingsSection("Рабочий день") {
                Stepper("Начало: \(model.configuration.workdayStartHour):00", value: Binding(
                    get: { model.configuration.workdayStartHour }, set: { model.setHour(\.workdayStartHour, value: $0) }
                ), in: 0...23)
                Stepper("Окончание: \(model.configuration.workdayEndHour):00", value: Binding(
                    get: { model.configuration.workdayEndHour }, set: { model.setHour(\.workdayEndHour, value: $0) }
                ), in: 1...24)
                settingNote("Для расчёта свободных промежутков от 30 минут. События на весь день и события со статусом «свободен» не занимают эти промежутки.")
                Divider()
                settingSwitch(CalendarViewPreferences.compactHoursTitle, isOn: $compactHours)
                settingNote("В видах «День» и «Неделя» сетка расширяется до начала ранней встречи или конца поздней.")
            }
            Text("Вид календаря, выбранные календари и состояние панелей запоминаются.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var generalOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSwitch("Запускать при входе в macOS", isOn: Binding(
                get: { model.autoStart }, set: { enabled in Task { await model.setAutoStart(enabled) } }
            ))
            settingsSection("Синхронизация с Яндекс Календарём") {
                Picker("В рабочее время", selection: Binding(
                    get: { model.refreshInterval }, set: { model.setRefreshInterval($0) }
                )) {
                    ForEach(CalendarRefreshInterval.workdayOptions, id: \.rawValue) { interval in
                        let label = interval == .recommended ? "5 мин (рекомендуется)" : "\(interval.rawValue) мин"
                        Text(label).tag(interval)
                    }
                }
                Picker("Вне рабочего времени", selection: Binding(
                    get: { model.outsideWorkdayRefreshInterval }, set: { model.setOutsideWorkdayRefreshInterval($0) }
                )) {
                    Text("Не обновлять").tag(nil as CalendarRefreshInterval?)
                    ForEach(CalendarRefreshInterval.outsideWorkdayOptions, id: \.rawValue) { interval in
                        let label = interval.rawValue < 60 ? "\(interval.rawValue) мин" : "\(interval.rawValue / 60) ч"
                        Text(label).tag(Optional(interval))
                    }
                }
                settingNote("Рабочее время: пн–пт, \(model.configuration.workdayStartHour):00–\(model.configuration.workdayEndHour):00 по времени Mac. Часы можно изменить в разделе «Вид → Рабочий день».")
                settingNote("Ручное обновление доступно в любое время.")
            }
            Text("Закрытие окна оставляет CalendarBar в строке меню. Команда «Выход» завершает работу и фоновые проверки.")
            Text("Без сети доступен сохранённый календарь. Время последнего обновления видно рядом с расписанием.")
            if !model.message.isEmpty { Text(model.message).foregroundStyle(.orange).textSelection(.enabled) }
            Button("Открыть историю изменений") { AppWindows.showActivity() }
        }.font(.callout)
    }

    private func option(_ key: WritableKeyPath<Configuration, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration[keyPath: key] }, set: { model.setOption(key, value: $0) })
    }

    private static let minutesFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        formatter.minimum = NSNumber(value: Configuration.reminderRange.lowerBound)
        formatter.maximum = NSNumber(value: Configuration.reminderRange.upperBound)
        return formatter
    }()

    private func reminderRow(_ title: String, enabled: WritableKeyPath<Configuration, Bool>,
                             minutes: WritableKeyPath<Configuration, Int>) -> some View {
        let value = Binding(get: { model.configuration[keyPath: minutes] }, set: {
            model.setReminderMinutes(minutes, value: $0)
        })
        return HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            TextField("Минуты", value: value, formatter: Self.minutesFormatter)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64)
                .accessibilityLabel(title + ": минут до начала")
                .disabled(!model.configuration[keyPath: enabled])
            Stepper(title + ": изменить число минут", value: value, in: Configuration.reminderRange).labelsHidden()
                .disabled(!model.configuration[keyPath: enabled])
            Text("мин.").font(.callout).foregroundStyle(.secondary)
            Toggle(title, isOn: option(enabled)).toggleStyle(.switch).labelsHidden()
        }
    }
}
