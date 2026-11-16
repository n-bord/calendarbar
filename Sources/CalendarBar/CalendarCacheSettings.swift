import SwiftUI

struct CalendarCacheSettings: View {
    private enum Scope {
        case account(String)
        case all

        var login: String? {
            if case .account(let login) = self { return login }
            return nil
        }
    }

    @ObservedObject var model: AppModel
    @State private var proposedScope: Scope?
    @State private var feedback = ""
    @State private var failed = false

    private var totalBytes: Int64 {
        let logins = Set(model.accounts.map(\.login) + [model.configuration.login])
        return logins.reduce(0) { $0 + model.calendarCacheBytes(for: $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 19))
                    .foregroundStyle(AppTheme.controlAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Занято кэшем").font(.headline)
                    Text(sizeLabel(totalBytes))
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                }
                Spacer()
                Button("Очистить весь кэш") { proposedScope = .all }
                    .disabled(model.busy || (totalBytes == 0 &&
                        !model.accounts.contains { model.hasCalendarCache(for: $0.login) }))
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))

            Text("Обновление загрузит ближайшие встречи заново. За более ранние даты события можно загрузить в календаре или поиске.")
                .foregroundStyle(.secondary)

            if model.accounts.isEmpty {
                Text("Сохранённых аккаунтов пока нет.").foregroundStyle(.secondary)
            } else {
                Divider()
                Text("По аккаунтам").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(model.accounts, id: \.login) { account in
                    accountRow(account.login)
                }
            }

            if model.busy {
                Text("Очистка доступна после окончания загрузки.").font(.caption).foregroundStyle(.secondary)
            }
            if !feedback.isEmpty {
                Text(feedback).font(.caption).foregroundStyle(failed ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .confirmationDialog("Очистить кэш календаря?", isPresented: Binding(
            get: { proposedScope != nil },
            set: { if !$0 { proposedScope = nil } }
        ), presenting: proposedScope) { scope in
            Button(scope.login == nil ? "Очистить весь кэш" : "Очистить кэш", role: .destructive) {
                clear(scope)
            }
            Button("Отмена", role: .cancel) {}
        } message: { scope in
            let subject = scope.login.map { "аккаунта «\(model.accountName($0))»" } ?? "всех аккаунтов"
            Text("Сохранённые встречи \(subject) будут удалены с этого Mac. Настройки, пароли, закрепления и личные напоминания сохранятся.")
        }
    }

    private func accountRow(_ login: String) -> some View {
        let label = model.accountLabel(login)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.accountName(login)).fontWeight(.medium)
                if !label.isEmpty { Text(login).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Text(sizeLabel(model.calendarCacheBytes(for: login)))
                .foregroundStyle(.secondary).monospacedDigit()
            Button("Очистить…") { proposedScope = .account(login) }
                .accessibilityLabel("Очистить кэш аккаунта " + model.accountName(login))
                .disabled(model.busy || !model.hasCalendarCache(for: login))
        }
        .padding(.vertical, 4)
    }

    private func sizeLabel(_ bytes: Int64) -> String {
        bytes == 0 ? "0 КБ" : bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "ru_RU")))
    }

    private func clear(_ scope: Scope) {
        let before = totalBytes
        do {
            try model.clearCalendarCache(for: scope.login)
            failed = false
            let released = before - totalBytes
            feedback = released > 0 ? "Кэш очищен. Освобождено \(sizeLabel(released))." : "Кэш очищен."
        } catch {
            failed = true
            feedback = "Не удалось полностью очистить кэш. " + error.localizedDescription
        }
    }
}
