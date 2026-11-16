import SwiftUI
import CalendarCore

struct AccountsSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var editor: AccountEditor?
    @State private var firstAccount = AccountEditor()
    @State private var pendingRemoval: Configuration?
    @State private var calendarDisclosure: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Подключение")
                    .font(.system(size: 25, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if !model.accounts.isEmpty {
                    Button { editor = AccountEditor() } label: {
                        Label("Добавить аккаунт", systemImage: "plus")
                    }
                    .disabled(model.busy || editor != nil)
                }
            }
            syncStatus
            Divider()
            if model.accounts.isEmpty {
                AccountConnectionEditor(
                    draft: $firstAccount,
                    savedLogins: [],
                    busy: model.busy,
                    canCancel: false,
                    save: save
                )
            }
            ForEach(model.accounts.sorted { $0.login.localizedStandardCompare($1.login) == .orderedAscending }, id: \.login) { account in
                accountSection(account)
            }
            if !model.accounts.isEmpty {
                DisclosureGroup {
                    ReadinessView(model: model).padding(.top, 8)
                } label: {
                    Label("Диагностика подключения", systemImage: "info.circle")
                }
            }
        }
        .sheet(item: $editor) { initial in
            VStack(alignment: .leading, spacing: 12) {
                if model.busy && !model.progress.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.progress).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                AccountConnectionEditor(
                    draft: Binding(get: { editor ?? initial }, set: { editor = $0 }),
                    savedLogins: Set(model.accounts.map(\.login)),
                    busy: model.busy,
                    canCancel: true,
                    cancel: { editor = nil },
                    save: save
                )
            }
            .padding(18)
            .frame(width: 500)
            .background(AppTheme.calendarChrome)
            .interactiveDismissDisabled(model.busy)
        }
        .alert("Удалить аккаунт?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { account in
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                model.disconnect(account.login)
            }.disabled(model.busy)
        } message: { account in
            Text("Пароль и локальные данные аккаунта \(account.login) будут удалены с этого Mac.")
        }
    }

    private var syncStatus: some View {
        let warning = model.connectionState == .unavailable || model.syncWarning != nil
        let updated = !warning && !model.busy && !model.activeAccountLogins.isEmpty && model.lastSync != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(model.progress.isEmpty ? "Обновляю расписание…" : model.progress)
                } else if updated, let date = model.lastSync {
                    Label {
                        Text("Расписание обновлено · " + CalendarDates.text(date, "d MMM, HH:mm"))
                    } icon: {
                        Image(systemName: "checkmark.circle").foregroundStyle(AppTheme.controlAccent)
                    }
                } else {
                    Label(model.readinessText, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(warning ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 8)
                if !model.activeAccountLogins.isEmpty {
                    Button { Task { await model.sync() } } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.busy)
                    .help("Обновить встречи во всех активных аккаунтах")
                }
            }
            .foregroundStyle(.secondary)
            if let details = model.message.isEmpty ? model.syncWarning : model.message {
                Text(details).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    private func accountSection(_ account: Configuration) -> some View {
        let login = account.login
        let name = model.accountName(login)
        let calendars = model.accountCalendars(login)
        let primary = login == model.configuration.login
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name).font(.headline).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                        if primary {
                            Text("Основной").font(.caption).foregroundStyle(.secondary)
                                .fixedSize()
                                .help("Рабочие часы и утренний обзор берутся из настроек основного аккаунта.")
                        }
                    }
                    if name != login {
                        Text(login).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                Toggle("Активен", isOn: Binding(
                    get: { model.activeAccountLogins.contains(login) },
                    set: { model.setAccountActive(login, active: $0) }
                ))
                .toggleStyle(.switch)
                .fixedSize()
                .accessibilityLabel("Активен: " + name)
                .help("Синхронизировать календари этого аккаунта.")
                .disabled(model.busy)
                Menu {
                    Button("Изменить…") {
                        editor = AccountEditor(original: account, label: model.accountLabel(login))
                    }
                    if !primary && model.activeAccountLogins.contains(login) {
                        Button("Сделать основным") { Task { await model.activateAccount(login) } }
                    }
                    Divider()
                    Button("Удалить аккаунт…", role: .destructive) { pendingRemoval = account }
                } label: {
                    Label("Действия для аккаунта " + name, systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.busy)
            }
            if let issue = model.accountSyncIssue(login) {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if calendars.isEmpty {
                Text("Календари пока не загружены").font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Календари · \(calendars.count)", isExpanded: Binding(
                    get: { calendarDisclosure[login] ?? primary },
                    set: { calendarDisclosure[login] = $0 }
                )) {
                    AccountCalendarSettings(model: model, calendars: calendars)
                        .padding(.top, 8)
                }
            }
            Divider()
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func save(_ draft: AccountEditor, verify: Bool) async {
        if let original = draft.original, !verify {
            model.setAccountLabel(draft.label, for: original.login)
            editor = nil
            return
        }
        if await model.connect(login: draft.normalizedLogin, password: draft.password, zone: draft.zone) {
            model.setAccountLabel(draft.label, for: draft.normalizedLogin)
            firstAccount = AccountEditor()
            editor = nil
        }
    }
}

private struct AccountEditor: Identifiable {
    let id = UUID()
    let original: Configuration?
    var login: String
    var label: String
    var password = ""
    var zone: String
    var normalizedLogin: String { login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    init(original: Configuration? = nil, label: String = "") {
        self.original = original
        self.login = original?.login ?? ""
        self.label = label
        self.zone = original?.zone ?? "Europe/Moscow"
    }
}

private struct AccountConnectionEditor: View {
    @Binding var draft: AccountEditor
    let savedLogins: Set<String>
    let busy: Bool
    let canCancel: Bool
    var cancel: () -> Void = {}
    let save: (AccountEditor, Bool) async -> Void

    private var needsConnection: Bool {
        draft.original == nil || !draft.password.isEmpty || draft.zone != draft.original?.zone
    }
    private var alreadySaved: Bool {
        draft.original == nil && savedLogins.contains(draft.normalizedLogin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "Добавление аккаунта" : "Настройки аккаунта")
                .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            field("Электронная почта") {
                if draft.original == nil {
                    TextField("Электронная почта", text: $draft.login, prompt: Text("name@example.com"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                    if alreadySaved {
                        Text("Этот аккаунт уже добавлен. Его можно изменить в списке аккаунтов.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text(draft.login).font(.callout).textSelection(.enabled)
                }
            }
            field("Название аккаунта") {
                TextField("Название аккаунта", text: $draft.label, prompt: Text("Например, Работа"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            field("Пароль приложения «Календарь»") {
                SecureField("Пароль приложения «Календарь»", text: $draft.password)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                Text(draft.original == nil
                     ? "Создайте пароль приложения в Яндекс ID для сервиса «Календарь»."
                     : "Оставьте поле пустым, чтобы сохранить прежний пароль.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Создать пароль в Яндекс ID", destination: URL(string: "https://id.yandex.ru/security/app-passwords")!)
                    .disabled(CalendarBarIdentity.isDemo)
                    .font(.caption)
            }
            field("Часовой пояс") {
                TextField("Часовой пояс", text: $draft.zone)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                Text("Используется для встреч, у которых не указан часовой пояс.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if !needsConnection {
                    Button("Проверить подключение") {
                        let value = draft
                        Task { await save(value, true) }
                    }
                }
                Spacer(minLength: 0)
                if canCancel { Button("Отмена", action: cancel) }
                Button(draft.original == nil ? "Подключить" : (needsConnection ? "Сохранить и проверить" : "Сохранить")) {
                    let value = draft
                    let verify = needsConnection
                    Task { await save(value, verify) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.normalizedLogin.isEmpty || alreadySaved ||
                          (draft.original == nil && draft.password.isEmpty))
            }
        }
        .disabled(busy)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium)).accessibilityHidden(true)
            content()
        }
    }
}

private struct AccountCalendarSettings: View {
    @ObservedObject var model: AppModel
    let calendars: [CalendarInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Календарь").padding(.leading, 4)
                Spacer()
                Text("В календаре").frame(width: 90)
                    .help("Показывать календарь в боковой панели окна календаря")
                Text("Уведомлять").frame(width: 88)
            }.font(.caption).foregroundStyle(.secondary)
            ForEach(calendars) { calendar in
                Divider()
                HStack {
                    CalendarSidebarColorButton(model: model, calendar: calendar)
                    Text(calendar.name).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    Toggle("Показывать «\(calendar.name)» в боковой панели", isOn: Binding(
                        get: { model.isCalendarListed(calendar) },
                        set: { model.includeCalendar(calendar.id, included: $0) }
                    ))
                    .toggleStyle(.checkbox).labelsHidden().frame(width: 90)
                    Toggle("Уведомлять о событиях календаря «\(calendar.name)»", isOn: Binding(
                        get: { model.isCalendarNotifying(calendar) },
                        set: { model.chooseCalendar(calendar.id, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox).labelsHidden().frame(width: 88).disabled(model.busy)
                }
            }
            Text("Уведомления работают независимо от показа в календаре.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}
