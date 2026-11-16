import SwiftUI
import CalendarCore

struct PinnedMeetingsView: View {
    @ObservedObject var model: AppModel
    @State private var editingID: URL?
    @State private var title = ""
    @State private var address = ""
    @State private var error = ""
    @State private var selectedLogin: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        let login = selectedLogin ?? model.configuration.login
        let pins = model.pins(for: login)
        VStack(alignment: .leading, spacing: 16) {
            if model.accounts.count > 1 {
                Picker("Аккаунт", selection: Binding(
                    get: { login }, set: { selectedLogin = $0; reset() }
                )) {
                    ForEach(model.accounts, id: \.login) { account in
                        Text(model.accountName(account.login)).tag(account.login)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(editingID == nil ? "Добавить встречу" : "Изменить встречу").font(.headline)
                TextField("Название, например «Командная комната»", text: $title)
                    .focused($titleFocused)
                TextField("Ссылка для подключения", text: $address)
                if !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if editingID != nil { Button("Отменить правку", action: reset) }
                    Spacer()
                    Button(editingID == nil ? "Закрепить" : "Сохранить") { save(for: login) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Divider()
            if pins.isEmpty {
                Text("Скопируйте ссылку на звонок из Телемоста или другого сервиса и вставьте её выше.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(Array(pins.enumerated()), id: \.element.id) { index, pin in
                        HStack {
                            Button { edit(pin) } label: {
                                Text(pin.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.help("Изменить название или ссылку")
                            Button { model.movePinned(pin, by: -1, for: login) } label: {
                                Label("Выше", systemImage: "chevron.up").labelStyle(.iconOnly)
                            }.disabled(index == 0)
                            Button { model.movePinned(pin, by: 1, for: login) } label: {
                                Label("Ниже", systemImage: "chevron.down").labelStyle(.iconOnly)
                            }.disabled(index == pins.count - 1)
                            Button {
                                if editingID == pin.id { reset() }
                                model.removePinned(pin, for: login)
                            } label: {
                                Label("Открепить", systemImage: "pin.slash").labelStyle(.iconOnly)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .listStyle(.inset)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { titleFocused = true }
        .onChange(of: model.accounts.map(\.login)) { logins in
            if let selectedLogin, !logins.contains(selectedLogin) {
                self.selectedLogin = nil
                reset()
            }
        }
        .onChange(of: model.configuration.login) { _ in if selectedLogin == nil { reset() } }
    }

    private func save(for login: String) {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let pin = PinnedMeeting(title: title, url: url) else {
            error = "Вставьте полную ссылку для подключения, начинающуюся с https:// или http://."
            return
        }
        guard model.savePinned(pin, replacing: editingID, for: login) else {
            if model.pins(for: login).contains(where: { $0.id == pin.id && $0.id != editingID }) {
                error = "Эта ссылка уже закреплена."
            } else {
                error = model.message.isEmpty ? "Закрепление изменилось. Откройте его заново." : model.message
            }
            return
        }
        reset()
    }

    private func edit(_ pin: PinnedMeeting) {
        editingID = pin.id
        title = pin.title
        address = pin.url.absoluteString
        error = ""
        titleFocused = true
    }

    private func reset() {
        editingID = nil
        title = ""
        address = ""
        error = ""
        titleFocused = true
    }
}
