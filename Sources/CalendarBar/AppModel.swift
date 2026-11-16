import AppKit
import Combine
import SwiftUI
import CryptoKit
import OSLog
import Security
import ServiceManagement
import UserNotifications
import CalendarCore

typealias Configuration = CalendarConfiguration

enum CalendarBarIdentity {
    static let identifier = Bundle.main.bundleIdentifier ?? "com.nbord.CalendarBar"
    static let isDevelopment = identifier == "com.nbord.CalendarBar.dev"
    static let isDemo = identifier == "com.nbord.CalendarBar.demo"
}

enum ConnectionState: Equatable {
    case notConnected, saved, checking, connected, unavailable, demo

    var title: String {
        switch self {
        case .notConnected: return "Аккаунт не подключён"
        case .saved: return "Аккаунт сохранён"
        case .checking: return "Проверяю подключение…"
        case .connected: return "Подключено к Яндекс Календарю"
        case .unavailable: return "Не удалось проверить подключение"
        case .demo: return "Демонстрационные данные"
        }
    }
}

private struct Snapshot: Codable {
    var login: String
    var initialized: Bool
    var meetings: [Meeting]
    var knownSeries: Set<String>
    var savedAt: Date?
    var syncWarning: String?
    var pendingBaselines: Set<String>?
}

private struct CalendarPage: Codable {
    let login: String
    let start: Date
    let end: Date
    var meetings: [Meeting]
    var savedAt: Date
    var partialWarning: String?
    var calendarIDs: Set<String>?
}

private struct CalendarBatch {
    var meetings: [Meeting] = []
    var refreshedCalendarIDs = Set<String>()
    var failedCalendars: [String: String] = [:]
    var failedResources: [String: [String: String]] = [:]

    var incompleteCalendarIDs: Set<String> { Set(failedCalendars.keys).union(failedResources.keys) }

    var warning: String? {
        let calendarFailure = failedCalendars.min { $0.key < $1.key }?.value
        let resourceFailure = failedResources.min { $0.key < $1.key }?.value.min { $0.key < $1.key }?.value
        guard let first = calendarFailure ?? resourceFailure else { return nil }
        return "Обновление частичное. Сохранённые встречи показаны там, где они доступны. " + first
    }

    func isMissingFreshData(for meeting: Meeting) -> Bool {
        if failedCalendars[meeting.calendarID] != nil { return true }
        guard let failures = failedResources[meeting.calendarID] else { return false }
        // Older cache entries may lack the original CalDAV resource URL.
        guard let url = meeting.resourceURL else { return true }
        return failures[url.absoluteString] != nil
    }
}

private struct ResourceSnapshot: Codable {
    let login: String
    let calendars: [CalendarInfo]
    let resources: [String: CachedCalendarResource]
}

private struct AccountData {
    var calendars: [CalendarInfo] = []
    var meetings: [Meeting] = []
    var personal = PersonalCalendarState()
    var pages: [CalendarPage] = []
    var resources: [String: CachedCalendarResource] = [:]
    var initialized = false
    var knownSeries = Set<String>()
    var pendingBaselines = Set<String>()
    var lastSync: Date?
    var warning: String?
}

enum Vault {
    private static let service = CalendarBarIdentity.identifier + ".caldav"
    private static let session = SessionCredentialCache()
    static func password(for account: String) throws -> String? {
        try session.read(for: account) { try readPassword(for: account) }
    }
    private static func readPassword(for account: String) throws -> String? {
        NSLog("CalendarBar: reading saved credential from Keychain")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw CalendarError.message("Не удалось прочитать пароль из Связки ключей (\(result)).")
        }
        return password
    }
    static func save(_ password: String, for account: String) throws {
        try session.save(password, for: account) { try writePassword(password, for: account) }
    }
    private static func writePassword(_ password: String, for account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var new = query
            new[kSecValueData as String] = Data(password.utf8)
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CalendarError.message("Не удалось сохранить пароль в Связке ключей (\(status)).") }
    }
    static func remove(for account: String) throws {
        try session.remove(for: account) { try deletePassword(for: account) }
    }
    static func clearSession(for account: String) {
        session.clear(for: account)
    }
    private static func deletePassword(for account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CalendarError.message("Не удалось удалить пароль из Связки ключей (\(status)).")
        }
    }
}

func stableHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct CalendarNavigationRequest: Equatable {
    enum Destination: Equatable {
        case day(Date)
        case meeting(Meeting)
    }

    let id = UUID()
    let destination: Destination
}

@MainActor
final class AppModel: ObservableObject {
    private static let refreshIntervalKey = "calendarRefreshIntervalMinutes"
    private static let outsideWorkdayIntervalKey = "calendarOutsideWorkdayRefreshIntervalMinutes"
    private static let activeAccountsKey = "activeAccountLogins"
    private static let accountLabelsKey = "calendarAccountLabels"
    private static let hiddenAccountsKey = "hiddenCalendarAccountLogins"
    private static let notificationLogger = Logger(subsystem: CalendarBarIdentity.identifier, category: "Notifications")
    static let shared = AppModel()
    private static let syncLogger = Logger(subsystem: CalendarBarIdentity.identifier, category: "Sync")
    @Published private(set) var configuration: Configuration
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    @Published private(set) var authorizationPending = false
    @Published private(set) var connectionState: ConnectionState = .notConnected
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus?
    @Published private(set) var pendingReminderIDs: Set<String>?
    @Published var message = ""
    @Published var notificationStatus = "Уведомления ещё не проверены"
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncWarning: String?
    @Published private(set) var standaloneMeeting: Meeting?
    @Published var autoStart = !CalendarBarIdentity.isDemo && SMAppService.mainApp.status == .enabled
    @Published private(set) var calendarMeetings: [Meeting] = []
    @Published private(set) var calendarLoading = false
    @Published private(set) var calendarError = ""
    @Published private(set) var calendarLastLoaded: Date?
    @Published private(set) var calendarFromCache = false
    @Published private(set) var accounts: [Configuration] = []
    @Published private(set) var activeAccountLogins = Set<String>()
    @Published private var accountLabels: [String: String] = [:]
    @Published private var hiddenAccounts = Set<String>()
    @Published private var accountData: [String: AccountData] = [:]
    @Published private(set) var searchResults: [Meeting] = []
    @Published private(set) var searchLoading = false
    @Published private(set) var searchError = ""
    @Published var calendarNavigation: CalendarNavigationRequest?
    @Published private(set) var menuTime = Date()
    @Published private(set) var refreshInterval = CalendarRefreshInterval(
        rawValue: UserDefaults.standard.integer(forKey: AppModel.refreshIntervalKey)
    ) ?? .recommended
    @Published private(set) var outsideWorkdayRefreshInterval: CalendarRefreshInterval? = {
        let minutes = UserDefaults.standard.object(forKey: AppModel.outsideWorkdayIntervalKey) as? Int
        if minutes == 0 { return nil }
        return minutes.flatMap(CalendarRefreshInterval.init(rawValue:)) ?? .outsideWorkdayDefault
    }()

    let clearedCalendarCaches = PassthroughSubject<Set<String>, Never>()

    private var searchID = UUID()
    private var syncTimer: Timer?
    private var lastSyncAttempt: Date?
    private var menuTimer: Timer?
    private var overviewTimer: Timer?
    private var started = false
    private var wakeObserver: NSObjectProtocol?
    private var clockObservers: [NSObjectProtocol] = []
    private var generation = 0
    private var requestInFlight = false
    private var blockedCredentials = Set<String>()
    private var notificationWorkInFlight = false
    private var notificationSettingsRevision = 0
    private var notificationRefreshRequested = false
    private var queuedChanges: [MeetingChange] = []
    private var calendarLoadID = UUID()
    private var displayedRange: Range<Date>?
    private let center = UNUserNotificationCenter.current()
    private static var folder: URL {
        let name = CalendarBarIdentity.isDemo ? "CalendarBar Demo" :
            (CalendarBarIdentity.isDevelopment ? "CalendarBar Dev" : "CalendarBar")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }
    private static func personalURL(_ login: String) -> URL {
        folder.appendingPathComponent("personal-" + stableHash(login) + ".json")
    }
    private static func accountFolder(_ login: String) -> URL {
        folder.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(stableHash(login), isDirectory: true)
    }

    private init() {
        if CalendarBarIdentity.isDemo {
            configuration = Configuration()
            loadDemo()
            return
        }
        let config: Configuration
        if let data = UserDefaults.standard.data(forKey: "configuration"),
           let decoded = try? JSONDecoder().decode(Configuration.self, from: data) { config = decoded }
        else { config = Configuration() }
        configuration = config
        if let data = UserDefaults.standard.data(forKey: "accountConfigurations"), let saved = try? JSONDecoder().decode([Configuration].self, from: data) { accounts = saved }
        if !config.login.isEmpty && !accounts.contains(where: { $0.login == config.login }) { accounts.append(config) }
        let savedLogins = Set(accounts.map(\.login))
        let enabled = UserDefaults.standard.stringArray(forKey: Self.activeAccountsKey) ?? [config.login]
        activeAccountLogins = Set(enabled).intersection(savedLogins)
        accountLabels = UserDefaults.standard.dictionary(forKey: Self.accountLabelsKey) as? [String: String] ?? [:]
        hiddenAccounts = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenAccountsKey) ?? []).intersection(savedLogins)
        let folder = Self.accountFolder(config.login)
        if !config.login.isEmpty {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for file in CalendarDiskCache.allCases {
                let old = file.url(in: Self.folder), target = file.url(in: folder)
                if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.moveItem(at: old, to: target)
                }
            }
        }
        for login in savedLogins.union([""]) { accountData[login] = Self.readAccount(login) }
        lastSync = activeProfiles.compactMap { accountData[$0.login]?.lastSync }.min()
        lastSyncAttempt = lastSync
        connectionState = activeAccountLogins.isEmpty ? .notConnected : .saved
        updateSyncWarning()
    }

    private func loadDemo() {
        let demo = DemoCalendar()
        let updated = demo.now.addingTimeInterval(-120)
        menuTime = demo.now
        lastSync = updated
        connectionState = .demo
        notificationStatus = "Демонстрационный режим"
        for profile in demo.profiles {
            var config = Configuration()
            config.login = profile.login
            config.zone = CalendarDates.calendar.timeZone.identifier
            config.calendarIDs = profile.calendars.map(\.sourceID)
            accounts.append(config)
            activeAccountLogins.insert(profile.login)
            accountLabels[profile.login] = profile.label
            let page = CalendarPage(login: profile.login, start: demo.range.lowerBound, end: demo.range.upperBound,
                meetings: profile.meetings, savedAt: updated, calendarIDs: Set(config.calendarIDs))
            accountData[profile.login] = AccountData(calendars: profile.calendars, meetings: profile.meetings,
                personal: profile.personal, pages: [page], initialized: true, lastSync: updated)
        }
        configuration = accounts.first ?? Configuration()
    }

    private static func readAccount(_ login: String) -> AccountData {
        let folder = accountFolder(login)
        func read<Value: Decodable>(_ name: String, as type: Value.Type) -> Value? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        var state = AccountData()
        if let data = try? Data(contentsOf: personalURL(login)),
           let personal = try? JSONDecoder().decode(PersonalCalendarState.self, from: data) {
            state.personal = personal
        }
        state.calendars = read("calendars.json", as: [CalendarInfo].self) ?? []
        if let pages = read(CalendarDiskCache.pages.rawValue, as: [CalendarPage].self) {
            state.pages = Array(pages.filter { $0.login == login }.prefix(32))
        }
        if let resources = read(CalendarDiskCache.resources.rawValue, as: ResourceSnapshot.self), resources.login == login {
            state.calendars = resources.calendars
            state.resources = resources.resources
        }
        if let snapshot = read(CalendarDiskCache.snapshot.rawValue, as: Snapshot.self), snapshot.login == login {
            state.meetings = snapshot.meetings
            state.initialized = snapshot.initialized
            state.knownSeries = snapshot.knownSeries
            state.lastSync = snapshot.savedAt
            state.warning = snapshot.syncWarning
            state.pendingBaselines = snapshot.pendingBaselines ?? []
        }
        return state
    }

    /// Start only after the app delegate has checked for an existing app process.
    func start() {
        guard !started else { return }
        started = true
        guard !CalendarBarIdentity.isDemo else { return }
        menuTime = Date()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.menuTime = Date() }
        }
        menuTimer?.tolerance = 1
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.menuTime = Date()
                    await self.syncIfDue()
                }
            }
        clockObservers = [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.syncIfDue() }
            }
        }
        // A notification daemon problem must never delay the calendar's initial sync.
        Task { await resumeNotifications() }
        Task { await syncIfDue() }
    }

    func setRefreshInterval(_ interval: CalendarRefreshInterval) {
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: Self.refreshIntervalKey)
        scheduleBackgroundSync()
    }

    func setOutsideWorkdayRefreshInterval(_ interval: CalendarRefreshInterval?) {
        guard interval != outsideWorkdayRefreshInterval else { return }
        outsideWorkdayRefreshInterval = interval
        UserDefaults.standard.set(interval?.rawValue ?? 0, forKey: Self.outsideWorkdayIntervalKey)
        scheduleBackgroundSync()
    }

    private var refreshSchedule: CalendarRefreshSchedule {
        CalendarRefreshSchedule(duringWorkday: refreshInterval, outsideWorkday: outsideWorkdayRefreshInterval,
            startHour: configuration.workdayStartHour, endHour: configuration.workdayEndHour)
    }

    private func scheduleBackgroundSync(retryDelay: TimeInterval = 0) {
        syncTimer?.invalidate()
        syncTimer = nil
        guard !CalendarBarIdentity.isDemo, started, activeAccountLogins.contains(where: { !blockedCredentials.contains($0) }),
              let check = refreshSchedule.nextCheck(after: Date(), lastAttempt: lastSyncAttempt,
                  calendar: CalendarDates.calendar, retryDelay: retryDelay) else { return }
        let timer = Timer(fire: check, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.syncIfDue() }
        }
        syncTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func syncIfDue() async {
        let now = Date()
        guard !requestInFlight,
              let interval = refreshSchedule.interval(at: now, calendar: CalendarDates.calendar),
              interval.isDue(after: lastSyncAttempt, at: now) else {
            scheduleBackgroundSync(retryDelay: requestInFlight ? 5 : 0)
            return
        }
        await sync()
    }

    var upcoming: [Meeting] {
        upcoming(at: Date())
    }

    func upcoming(at now: Date) -> [Meeting] {
        let notifying = notifyingCalendarIDs
        return meetings.filter { !$0.cancelled && !$0.declined(by: configuration.login) &&
            $0.end > now && notifying.contains($0.calendarID) }
            .sorted { lhs, rhs in lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start }
    }
    func menuSchedule(at now: Date) -> MenuSchedule {
        // The sync snapshot is authoritative in its range; a loaded page fills gaps.
        let events = mergedMeetings(meetings + calendarMeetings).map(displayedMeeting)
        return MenuSchedule(meetings: events, mode: .currentAndUpcoming,
            visibleCalendarIDs: visibleCalendarIDs, account: configuration.login, now: now,
            calendar: CalendarDates.calendar, includeFinishedToday: true)
    }

    func hasFreshMenuSchedule(at now: Date) -> Bool {
        if CalendarBarIdentity.isDemo { return true }
        let calendar = CalendarDates.calendar
        let interval = refreshSchedule.interval(at: now, calendar: calendar) ?? refreshSchedule.duringWorkday
        guard !busy, connectionState == .connected, syncWarning == nil, !visibleCalendarIDs.isEmpty,
              let lastSync, (0...interval.seconds * 3).contains(now.timeIntervalSince(lastSync)) else {
            return false
        }
        let today = CalendarDates.dayRange(now)
        return activeProfiles.filter { isAccountVisible($0.login) }.allSatisfy { profile in
            // A snapshot from another account or a page from before a calendar
            // was enabled cannot establish that today's schedule is empty.
            guard accountData[profile.login]?.lastSync != nil,
                  let page = cachedPage(for: profile.login, range: today),
                  page.partialWarning == nil, page.calendarIDs != nil,
                  (0...interval.seconds * 3).contains(now.timeIntervalSince(page.savedAt)) else { return false }
            return pageCoversListedCalendars(page, for: profile.login)
        }
    }

    func menuLabel(at now: Date) -> String {
        guard configuration.menuCountdownWindow != .hidden else { return "" }
        let schedule = menuSchedule(at: now)
        if !schedule.ongoing.isEmpty { return "Встреча по плану" }
        guard let next = schedule.next.first else { return "" }
        return configuration.menuCountdownWindow.label(start: next.start, now: now)
    }

    @discardableResult
    func connect(login: String, password: String, zone: String) async -> Bool {
        guard !CalendarBarIdentity.isDemo else { return false }
        guard !requestInFlight else { return false }
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard login.contains("@"), !login.contains(":"), !login.contains("\n"), TimeZone(identifier: zone) != nil else {
            message = "Укажите полный рабочий e-mail и часовой пояс, например Europe/Moscow."; return false
        }
        requestInFlight = true; busy = true
        let previousState = connectionState
        connectionState = .checking
        progress = "Проверяю подключение к Яндексу…"
        defer { requestInFlight = false; busy = false; progress = "" }
        blockedCredentials.remove(login)
        do {
            let secret = password.isEmpty ? try await savedPassword(for: login) ?? "" : password
            guard !secret.isEmpty else { throw CalendarError.message("Введите пароль приложения Яндекс ID типа «Календарь».") }
            let found = try await CalDAVClient(login: login, password: secret).calendars()
            if !password.isEmpty {
                progress = "Сохраняю пароль в Связке ключей…"
                try await Task.detached(priority: .userInitiated) { try Vault.save(secret, for: login) }.value
            }
            let existing = profile(for: login)
            var config = existing ?? Configuration()
            config.login = login
            if config.zone != zone {
                accountData[login]?.pages = []
                accountData[login]?.initialized = false
                accountData[login]?.pendingBaselines = []
            }
            config.zone = zone
            if existing == nil { config.calendarIDs = found.map(\.id) }
            if accountData[login] == nil { accountData[login] = Self.readAccount(login) }
            accountData[login]?.calendars = found
            accountData[login]?.warning = nil
            if existing == nil { activeAccountLogins.insert(login) }
            if configuration.login.isEmpty || configuration.login == login { configuration = config }
            saveProfile(config)
            persistAccountPreferences()
            try? saveCalendarPages(for: login)
            try? saveResources(for: login)
            connectionState = activeAccountLogins.isEmpty ? .notConnected : .connected
            updateSyncWarning()
            message = "Подключение проверено. Найдено календарей: \(found.count)."
            if activeAccountLogins.contains(login) {
                queueSync(for: login)
            }
            return true
        } catch {
            connectionState = previousState
            message = error.localizedDescription
            return false
        }
    }

    func sync() async { await sync(only: activeAccountLogins) }

    private func queueSync(for login: String) {
        Task {
            while requestInFlight && activeAccountLogins.contains(login) {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            }
            await sync(only: [login])
        }
    }

    private func sync(only logins: Set<String>) async {
        guard !CalendarBarIdentity.isDemo, !requestInFlight else { return }
        let profiles = activeProfiles.filter { logins.contains($0.login) && !blockedCredentials.contains($0.login) }
        guard !profiles.isEmpty else {
            scheduleBackgroundSync()
            return
        }
        let now = Date()
        lastSyncAttempt = now
        syncTimer?.invalidate()
        requestInFlight = true; busy = true
        let token = generation
        if connectionState != .connected { connectionState = .checking }
        defer {
            requestInFlight = false; busy = false; progress = ""
            scheduleBackgroundSync()
        }
        let calendar = CalendarDates.calendar
        let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let end = calendar.date(byAdding: .day, value: 14, to: now)!
        let range = start..<end
        var changes: [MeetingChange] = []
        var didConnect = false
        for config in profiles {
            guard token == generation, !Task.isCancelled else { break }
            do {
                let batch = try await fetchAccount(config, range: range, kind: .background) { token == self.generation }
                guard token == generation, !Task.isCancelled else { break }
                didConnect = true
                changes += applySync(batch, to: config, range: range, now: now)
                try persistSnapshot(for: config.login)
                try? saveCalendarPages(for: config.login)
                try? saveResources(for: config.login)
            } catch is CancellationError {
                break
            } catch {
                guard token == generation, !Task.isCancelled else { break }
                accountData[config.login]?.warning = error.localizedDescription
                Self.syncLogger.error("Account refresh failed")
            }
        }
        guard token == generation, !Task.isCancelled else { return }
        if didConnect { connectionState = .connected }
        else if profiles.count == activeAccountLogins.count { connectionState = .unavailable }
        lastSync = activeProfiles.compactMap { accountData[$0.login]?.lastSync }.min()
        updateSyncWarning()
        message = syncWarning ?? ""
        if displayedRange != nil { publishDisplayedRange() }
        updateNotifications(changes: changes)
    }

    private func applySync(_ batch: CalendarBatch, to config: Configuration, range: Range<Date>, now: Date) -> [MeetingChange] {
        let login = config.login
        var state = accountData[login] ?? AccountData()
        let fresh = mergedMeetings(batch.meetings)
        if !state.initialized { state.pendingBaselines.formUnion(batch.incompleteCalendarIDs) }
        let changes = ChangeDetector.changes(old: state.meetings,
            new: fresh.filter { !state.pendingBaselines.contains($0.calendarID) },
            knownSeries: state.knownSeries, initialized: state.initialized, now: now,
            localWrites: state.personal.localWrites, account: login)
        let fetchedSeries = Set(fresh.map(\.seriesID))
        state.personal.localWrites.removeAll { fetchedSeries.contains($0.seriesID) || now.timeIntervalSince($0.savedAt) >= 600 }
        let snoozes = state.personal.snoozes.map(\.meeting).filter(batch.isMissingFreshData)
        state.personal.reconcileSnoozes(with: snoozes + fresh, refreshedRange: range,
            calendarIDs: Set(config.calendarIDs), now: now)
        recordActivity(changes, in: &state.personal)
        state.meetings = meetingsFromBatch(batch, retaining: state.meetings, in: range, login: login)
        mergePages(&state.pages, batch: batch, login: login, range: range, now: now)
        state.knownSeries.formUnion(fetchedSeries)
        state.pendingBaselines.subtract(batch.refreshedCalendarIDs.subtracting(batch.incompleteCalendarIDs))
        state.initialized = true
        state.warning = batch.warning
        if state.warning == nil { state.lastSync = now }
        accountData[login] = state
        persistPersonal(for: login)
        return changes.map {
            MeetingChange(meeting: scoped($0.meeting, to: login), kind: $0.kind,
                previous: $0.previous.map { scoped($0, to: login) })
        }
    }

    func chooseCalendar(_ id: String, enabled: Bool) {
        guard let calendar = calendar(withID: id), let login = calendar.accountLogin,
              var config = profile(for: login), config.calendarIDs.contains(calendar.sourceID) != enabled else { return }
        if enabled { config.calendarIDs.append(calendar.sourceID) }
        else { config.calendarIDs.removeAll { $0 == calendar.sourceID } }
        saveProfile(config)
        accountData[login]?.initialized = false
        accountData[login]?.pendingBaselines = []
        notificationSettingsRevision &+= 1
        updateNotifications()
        if activeAccountLogins.contains(login) { queueSync(for: login) }
    }

    func setOption(_ key: WritableKeyPath<Configuration, Bool>, value: Bool) {
        guard configuration[keyPath: key] != value else { return }
        configuration[keyPath: key] = value
        notificationSettingsRevision &+= 1
        persistConfiguration()
        updateNotifications()
    }

    func setReminderMinutes(_ key: WritableKeyPath<Configuration, Int>, value: Int) {
        let minutes = min(max(value, Configuration.reminderRange.lowerBound), Configuration.reminderRange.upperBound)
        guard configuration[keyPath: key] != minutes else { return }
        configuration[keyPath: key] = minutes
        notificationSettingsRevision &+= 1
        persistConfiguration()
        updateNotifications()
    }

    func setMenuCountdownWindow(_ window: MenuCountdownWindow) {
        guard configuration.menuCountdownWindow != window else { return }
        configuration.menuCountdownWindow = window
        if !CalendarBarIdentity.isDemo { menuTime = Date() }
        persistConfiguration()
    }

    func setAutoStart(_ enabled: Bool) async {
        guard !CalendarBarIdentity.isDemo else { autoStart = false; return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
            autoStart = SMAppService.mainApp.status == .enabled
            if enabled && !autoStart { message = "Разрешите автозапуск CalendarBar в Системных настройках → Основные → Объекты входа." }
        } catch { autoStart = SMAppService.mainApp.status == .enabled; message = error.localizedDescription }
    }

    func disconnect(_ login: String? = nil) {
        guard !CalendarBarIdentity.isDemo else { return }
        let login = login ?? configuration.login
        guard !requestInFlight, profile(for: login) != nil else { return }
        do { try Vault.remove(for: login); try TelemostVault.remove(for: login) }
        catch { message = error.localizedDescription; return }
        activeAccountLogins.remove(login)
        blockedCredentials.remove(login)
        accountLabels.removeValue(forKey: login)
        hiddenAccounts.remove(login)
        accounts.removeAll { $0.login == login }
        accountData.removeValue(forKey: login)
        if configuration.login == login { configuration = activeProfiles.first ?? Configuration() }
        invalidateAccountPresentation()
        persistConfiguration()
        persistAccountPreferences()
        UserDefaults.standard.removeObject(forKey: "telemost.configured." + stableHash(login))
        do {
            for url in [Self.personalURL(login), Self.accountFolder(login)] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            message = "Аккаунт отключён. Пароль и кэш встреч удалены."
        } catch {
            message = "Аккаунт отключён, но не удалось удалить локальный кэш: " + error.localizedDescription
        }
    }

    private func savedPassword(for login: String) async throws -> String? {
        if blockedCredentials.contains(login) {
            throw CalendarError.message("Разрешите доступ к сохранённому паролю в настройках подключения.")
        }
        progress = "Читаю сохранённый пароль…"
        do { return try await Task.detached(priority: .userInitiated) { try Vault.password(for: login) }.value }
        catch {
            blockedCredentials.insert(login)
            throw CalendarError.message("Нет доступа к сохранённому паролю. Откройте «Изменить подключение» и сохраните его повторно.")
        }
    }

    private func saveProfile(_ config: Configuration) {
        if let index = accounts.firstIndex(where: { $0.login == config.login }) { accounts[index] = config }
        else { accounts.append(config) }
        if configuration.login == config.login { configuration = config }
        persistConfiguration()
    }

    private func persistConfiguration() {
        if !configuration.login.isEmpty, let index = accounts.firstIndex(where: { $0.login == configuration.login }) {
            accounts[index] = configuration
        }
        guard !CalendarBarIdentity.isDemo else { return }
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: "configuration") }
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: "accountConfigurations") }
    }

    private func persistAccountPreferences() {
        guard !CalendarBarIdentity.isDemo else { return }
        UserDefaults.standard.set(activeAccountLogins.sorted(), forKey: Self.activeAccountsKey)
        UserDefaults.standard.set(hiddenAccounts.sorted(), forKey: Self.hiddenAccountsKey)
        UserDefaults.standard.set(accountLabels, forKey: Self.accountLabelsKey)
    }

    private func writeAccount<Value: Encodable>(_ value: Value, named name: String, for login: String) throws {
        guard !CalendarBarIdentity.isDemo else { return }
        let folder = Self.accountFolder(login)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func cacheDirectories(for login: String) -> [URL] {
        let directory = Self.accountFolder(login)
        return login == configuration.login ? [directory, Self.folder] : [directory]
    }

    func calendarCacheBytes(for login: String) -> Int64 {
        cacheDirectories(for: login).reduce(0) { $0 + CalendarDiskCache.size(in: $1) }
    }

    func hasCalendarCache(for login: String) -> Bool {
        calendarCacheBytes(for: login) > 0 ||
            accountData[login].map { !$0.pages.isEmpty || !$0.resources.isEmpty || !$0.meetings.isEmpty } == true ||
            searchResults.contains { owner(of: $0) == login }
    }

    func clearCalendarCache(for login: String? = nil) throws {
        guard !CalendarBarIdentity.isDemo else { return }
        guard !requestInFlight else {
            throw CalendarError.message("Дождитесь окончания загрузки календаря и попробуйте снова.")
        }
        let logins = login.map { [$0] } ?? Array(Set(accounts.map(\.login) + [configuration.login]))
        var cleared = Set<String>()
        var failures: [String] = []
        for login in logins.sorted() {
            guard hasCalendarCache(for: login) else { continue }
            let directories = cacheDirectories(for: login)
            let accountName = login.isEmpty ? "Старый кэш" : accountName(login)
            var state = accountData[login] ?? AccountData()

            for file in CalendarDiskCache.allCases {
                do {
                    // Keep the calendar directory available offline after removing the cached event bodies.
                    if file == .resources && !login.isEmpty {
                        try writeAccount(state.calendars, named: "calendars.json", for: login)
                    }
                    for directory in directories.reversed() { try file.remove(from: directory) }
                    switch file {
                    case .snapshot:
                        state.meetings = []
                        state.initialized = false
                        state.knownSeries = []
                        state.pendingBaselines = []
                        state.lastSync = nil
                        state.warning = nil
                    case .pages: state.pages = []
                    case .resources: state.resources = [:]
                    }
                    cleared.insert(login)
                } catch {
                    failures.append(accountName + " · " + error.localizedDescription)
                }
            }
            accountData[login] = state
        }

        if !cleared.isEmpty {
            searchResults.removeAll { cleared.contains(owner(of: $0)) }
            queuedChanges.removeAll { cleared.contains(owner(of: $0.meeting)) }
            searchError = ""
            if let meeting = standaloneMeeting, cleared.contains(owner(of: meeting)) { standaloneMeeting = nil }
            if let navigation = calendarNavigation, case .meeting(let meeting) = navigation.destination,
               cleared.contains(owner(of: meeting)) { calendarNavigation = nil }
            // Resume at the usual interval instead of immediately downloading the cache again.
            lastSyncAttempt = Date()
            invalidateAccountPresentation()
            clearedCalendarCaches.send(cleared)
        }
        if !failures.isEmpty {
            throw CalendarError.message(failures.joined(separator: "\n"))
        }
    }

    private func saveCalendarPages(for login: String) throws {
        let encoder = JSONEncoder()
        var stored: [CalendarPage] = [], bytes = 2
        for page in (accountData[login]?.pages ?? []).prefix(32) {
            let count = try encoder.encode(page).count + 1
            if bytes + count <= 16 * 1024 * 1024 { stored.append(page); bytes += count }
        }
        try writeAccount(stored, named: CalendarDiskCache.pages.rawValue, for: login)
    }

    private func mergePages(_ pages: inout [CalendarPage], batch: CalendarBatch, login: String,
                            range: Range<Date>, now: Date) {
        let listed = Set(accountData[login]?.personal.listedCalendarIDs(in: accountData[login]?.calendars ?? []) ?? [])
        for index in pages.indices {
            let pageRange = pages[index].start..<pages[index].end
            guard pageRange.overlaps(range) else { continue }
            let kept = pages[index].meetings.filter {
                !batch.refreshedCalendarIDs.contains($0.calendarID) || batch.isMissingFreshData(for: $0) ||
                    !intersects($0, range: range, login: login)
            }
            let fresh = batch.meetings.filter { intersects($0, range: pageRange, login: login) }
            pages[index].meetings = mergedMeetings(fresh + kept)
            if let warning = batch.warning { pages[index].partialWarning = warning }
            else if range.lowerBound <= pageRange.lowerBound && range.upperBound >= pageRange.upperBound &&
                        listed.isSubset(of: batch.refreshedCalendarIDs) {
                pages[index].partialWarning = nil
                pages[index].savedAt = now
                pages[index].calendarIDs = batch.refreshedCalendarIDs
            }
        }
        if listed.isSubset(of: batch.refreshedCalendarIDs) && batch.warning == nil {
            storePage(CalendarPage(login: login, start: range.lowerBound, end: range.upperBound,
                meetings: batch.meetings, savedAt: now, calendarIDs: batch.refreshedCalendarIDs), in: &pages)
        }
    }

    private func storePage(_ page: CalendarPage, in pages: inout [CalendarPage]) {
        pages.removeAll { $0.start == page.start && $0.end == page.end }
        pages.insert(page, at: 0)
        pages = Array(pages.prefix(32))
    }

    private func intersects(_ meeting: Meeting, range: Range<Date>, login: String) -> Bool {
        CalendarLayout.intersects(displayedMeeting(meeting.scoped(to: login)), range: range)
    }

    private func meetingsFromBatch(_ batch: CalendarBatch, retaining prior: [Meeting],
                                   in range: Range<Date>, login: String) -> [Meeting] {
        let retained = prior.filter { batch.isMissingFreshData(for: $0) && intersects($0, range: range, login: login) }
        return mergedMeetings(batch.meetings + retained)
    }

    private enum FetchKind { case background, window, search }

    private func fetchAccount(_ config: Configuration, range: Range<Date>, kind: FetchKind,
                              isCurrent: () -> Bool) async throws -> CalendarBatch {
        let login = config.login
        guard let secret = try await savedPassword(for: login) else {
            throw CalendarError.message("Для подключения введите пароль приложения в настройках.")
        }
        guard isCurrent() else { throw CancellationError() }
        let client = CalDAVClient(login: login, password: secret)
        progress = "Получаю календари · " + accountName(login)
        let found = try await client.calendars()
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let state = accountData[login] ?? AccountData()
        let listed = state.personal.listedCalendarIDs(in: state.calendars)
        let requested = kind == .background ? listed.union(config.calendarIDs) : listed
        let missing = requested.subtracting(found.map(\.id))
        if kind != .search {
            accountData[login, default: AccountData()].calendars =
                (found + state.calendars.filter { missing.contains($0.id) }).sorted { $0.name < $1.name }
        }
        let included = found.filter {
            !state.personal.hiddenCalendars.contains($0.id) ||
                (kind == .background && config.calendarIDs.contains($0.id))
        }
        let zone = TimeZone(identifier: config.zone) ?? .current
        let displayCalendar = CalendarDates.calendar
        var batch = CalendarBatch()
        batch.refreshedCalendarIDs = Set(included.map(\.id))
        for id in missing { batch.failedCalendars[id] = "Один из календарей недоступен. Проверьте права доступа." }
        for (index, calendar) in included.enumerated() {
            guard isCurrent() else { throw CancellationError() }
            try Task.checkCancellation()
            progress = "\(accountName(login)) · \(calendar.name) (\(index + 1)/\(included.count))"
            do {
                let result = try await client.fetchMeetings(in: calendar, start: range.lowerBound, end: range.upperBound,
                    fallbackZone: zone, cached: accountData[login]?.resources ?? [:], displayCalendar: displayCalendar)
                guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
                accountData[login, default: AccountData()].resources.merge(
                    result.resources.map { ($0.href, $0) }, uniquingKeysWith: { _, latest in latest })
                batch.meetings += result.meetings
                if !result.failedResources.isEmpty {
                    batch.failedResources[calendar.id] = result.failedResources.mapValues { "Календарь «\(calendar.name)»: " + $0 }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
                batch.failedCalendars[calendar.id] = "Календарь «\(calendar.name)»: " + error.localizedDescription
            }
        }
        return batch
    }

    private func saveResources(for login: String) throws {
        guard let state = accountData[login] else { return }
        let ordered = state.resources.values.sorted { $0.lastUsed > $1.lastUsed }
        var size = 0
        let resources = Dictionary(ordered.prefix(3000).filter {
            size += $0.data.utf8.count
            return size <= 24 * 1024 * 1024
        }.map { ($0.href, $0) }, uniquingKeysWith: { first, _ in first })
        accountData[login]?.resources = resources
        try writeAccount(ResourceSnapshot(login: login, calendars: state.calendars, resources: resources),
            named: CalendarDiskCache.resources.rawValue, for: login)
    }

    private func cachedPage(for login: String, range: Range<Date>) -> CalendarPage? {
        (accountData[login]?.pages ?? []).filter {
            $0.start <= range.lowerBound && $0.end >= range.upperBound
        }.max { $0.savedAt < $1.savedAt }
    }

    private func cachedMeetings(for login: String, range: Range<Date>) -> [Meeting] {
        guard let state = accountData[login] else { return [] }
        let fallback = state.meetings + state.pages.flatMap(\.meetings)
        let events: [Meeting]
        if let page = cachedPage(for: login, range: range) {
            let missing = page.calendarIDs.map { covered in fallback.filter { !covered.contains($0.calendarID) } } ?? []
            events = mergedMeetings(page.meetings + missing)
        } else {
            events = mergedMeetings(fallback)
        }
        return events.filter { intersects($0, range: range, login: login) }
    }

    private func pageCoversListedCalendars(_ page: CalendarPage, for login: String) -> Bool {
        guard let covered = page.calendarIDs, let state = accountData[login] else { return true }
        return state.personal.listedCalendarIDs(in: state.calendars).isSubset(of: covered)
    }

    private func publishDisplayedRange(fromCache: Bool = false, issues: [String] = []) {
        guard let range = displayedRange else { return }
        calendarMeetings = activeProfiles.flatMap { config in
            cachedMeetings(for: config.login, range: range).map { scoped($0, to: config.login) }
        }
        let pages = activeProfiles.compactMap { cachedPage(for: $0.login, range: range) }
        calendarLastLoaded = pages.count == activeProfiles.count ? pages.map(\.savedAt).min() : nil
        calendarFromCache = fromCache
        calendarError = (issues + pages.compactMap(\.partialWarning)).first ?? ""
    }

    func loadCalendar(range: Range<Date>, force: Bool = false) async {
        while !started {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let loadID = UUID()
        calendarLoadID = loadID
        displayedRange = range
        if CalendarBarIdentity.isDemo {
            publishDisplayedRange()
            return
        }
        publishDisplayedRange(fromCache: true)
        let profiles = activeProfiles.filter { config in
            if force { return true }
            guard let page = cachedPage(for: config.login, range: range), page.partialWarning == nil,
                  pageCoversListedCalendars(page, for: config.login) else { return true }
            return !CalendarCachePolicy.isFresh(cachedRange: page.start..<page.end, savedAt: page.savedAt, requestedRange: range)
        }
        guard !profiles.isEmpty else {
            calendarLoading = false
            return
        }
        calendarLoading = true
        defer { if loadID == calendarLoadID { calendarLoading = false } }
        while requestInFlight {
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard loadID == calendarLoadID, !Task.isCancelled else { return }
        }
        guard loadID == calendarLoadID, !Task.isCancelled else { return }
        requestInFlight = true; busy = true
        defer { requestInFlight = false; busy = false; progress = "" }
        var issues: [String] = []
        for config in profiles {
            let login = config.login
            do {
                let batch = try await fetchAccount(config, range: range, kind: .window) { self.calendarLoadID == loadID }
                guard loadID == calendarLoadID, !Task.isCancelled else { return }
                let previous = cachedMeetings(for: login, range: range)
                let fetched = meetingsFromBatch(batch, retaining: previous, in: range, login: login)
                let events = mergedMeetings(fetched + previous.filter { !batch.refreshedCalendarIDs.contains($0.calendarID) })
                let page = CalendarPage(login: login, start: range.lowerBound, end: range.upperBound,
                    meetings: events, savedAt: Date(), partialWarning: batch.warning, calendarIDs: batch.refreshedCalendarIDs)
                var pages = accountData[login]?.pages ?? []
                storePage(page, in: &pages)
                accountData[login, default: AccountData()].pages = pages
                try? saveCalendarPages(for: login)
                try? saveResources(for: login)
            } catch is CancellationError { return }
            catch { issues.append(accountName(login) + ": " + error.localizedDescription) }
        }
        guard loadID == calendarLoadID, !Task.isCancelled else { return }
        publishDisplayedRange(fromCache: !issues.isEmpty, issues: issues)
    }

    func hasCompleteCalendarData(for range: Range<Date>) -> Bool {
        guard !activeProfiles.isEmpty, !calendarLoading, calendarError.isEmpty,
              let displayedRange, displayedRange.lowerBound <= range.lowerBound,
              displayedRange.upperBound >= range.upperBound else { return false }
        return activeProfiles.filter { isAccountVisible($0.login) }.allSatisfy {
            let login = $0.login
            return cachedPage(for: login, range: range).map {
                $0.partialWarning == nil && pageCoversListedCalendars($0, for: login)
            } ?? false
        }
    }

    private func persistSnapshot(for login: String) throws {
        guard let state = accountData[login] else { return }
        let snapshot = Snapshot(login: login, initialized: state.initialized, meetings: state.meetings,
            knownSeries: state.knownSeries, savedAt: state.lastSync, syncWarning: state.warning, pendingBaselines: state.pendingBaselines)
        try writeAccount(snapshot, named: CalendarDiskCache.snapshot.rawValue, for: login)
    }

    @discardableResult
    func refreshNotificationStatus() async -> Bool {
        guard !CalendarBarIdentity.isDemo else { return false }
        do {
            let settings = try await NotificationBridge.settings(center)
            // The activation event from our own permission prompt must not overwrite its progress.
            if authorizationPending { return notificationsAllowed(settings.authorizationStatus) }
            return applyNotificationSettings(settings)
        } catch {
            if !authorizationPending { notificationStatus = NotificationBridge.message(for: error) }
            return false
        }
    }

    private func notificationsAllowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    @discardableResult
    private func applyNotificationSettings(_ settings: UNNotificationSettings) -> Bool {
        notificationAuthorization = settings.authorizationStatus
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            if settings.alertSetting == .disabled {
                notificationStatus = "Уведомления разрешены, но баннеры выключены. Выберите «Баннеры» или «Предупреждения» в настройках macOS."
            } else if settings.soundSetting == .disabled {
                notificationStatus = "Уведомления разрешены. Звук выключен в настройках macOS."
            } else {
                notificationStatus = "Уведомления разрешены"
            }
            return true
        case .denied:
            notificationStatus = NotificationBridge.denied
        case .notDetermined:
            notificationStatus = "Нажмите «Разрешить уведомления» и ответьте на системный запрос macOS."
        default:
            notificationStatus = "Проверьте разрешение CalendarBar в Системных настройках → Уведомления."
        }
        return false
    }

    func openNotificationSettings() {
        guard !CalendarBarIdentity.isDemo else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    /// Recheck after returning from System Settings; no authorization prompt here.
    func resumeNotifications() async {
        guard !authorizationPending else { return }
        if await refreshNotificationStatus() { updateNotifications() }
    }

    var notificationPermissionButton: String {
        switch notificationAuthorization {
        case .denied: return "Разрешить в macOS"
        case .authorized, .provisional: return "Настройки уведомлений"
        default: return "Разрешить уведомления"
        }
    }

    func notificationPermissionAction() async {
        if let status = notificationAuthorization, status != .notDetermined {
            openNotificationSettings()
        } else {
            await requestNotifications(openSettingsIfDenied: true)
        }
    }

    @discardableResult
    func requestNotifications(openSettingsIfDenied: Bool = false) async -> Bool {
        guard !CalendarBarIdentity.isDemo, !authorizationPending else { return false }
        authorizationPending = true
        defer { authorizationPending = false }
        do {
            let settings = try await NotificationBridge.settings(center)
            // macOS records denial; repeatedly requesting authorization cannot undo it.
            if settings.authorizationStatus != .notDetermined {
                let allowed = applyNotificationSettings(settings)
                if allowed { updateNotifications() }
                else if openSettingsIfDenied { openNotificationSettings() }
                return allowed
            }
            NSApp.activate(ignoringOtherApps: true)
            notificationStatus = "Ожидаю разрешение macOS. Проверьте системное окно запроса…"
            let allowed = try await NotificationBridge.authorize(center)
            let updated = try await NotificationBridge.settings(center)
            applyNotificationSettings(updated)
            if allowed { updateNotifications() }
            return allowed
        } catch {
            notificationStatus = NotificationBridge.message(for: error)
            return false
        }
    }

    /// Coalesce work and keep it outside the connection/sync busy flag.
    /// Never invoke the permission prompt automatically from this worker.
    private func updateNotifications(changes: [MeetingChange] = []) {
        guard !CalendarBarIdentity.isDemo else { return }
        queuedChanges.append(contentsOf: changes)
        notificationRefreshRequested = true
        if pendingReminderIDs != nil { pendingReminderIDs = nil }
        guard !notificationWorkInFlight else { return }
        notificationWorkInFlight = true
        Task {
            defer { notificationWorkInFlight = false }
            repeat {
                notificationRefreshRequested = false
                let pendingChanges = queuedChanges
                queuedChanges.removeAll()
                let token = generation
                guard await refreshNotificationStatus(), token == generation else { continue }
                let revision = notificationSettingsRevision
                do {
                    var notified = Set<String>()
                    for change in pendingChanges {
                        guard token == generation else { break }
                        let key = change.meeting.id + change.kind.rawValue
                        guard let config = profile(for: owner(of: change.meeting)),
                              activeAccountLogins.contains(config.login), config.calendarIDs.contains(change.meeting.sourceCalendarID),
                              !notified.contains(key), !change.meeting.declined(by: config.login) else { continue }
                        notified.insert(key)
                        if (change.kind == .new && config.notifyNew) || (change.kind != .new && config.notifyChanges) {
                            let entry = ActivityEntry(change: change)
                            if entry.important || config.notifyMinorChanges { try await alert(change) }
                        }
                    }
                    if token == generation { try await scheduleReminders() }
                } catch { notificationStatus = NotificationBridge.message(for: error) }
                if !notificationRefreshRequested, token == generation, revision == notificationSettingsRevision,
                   let pending = try? await NotificationBridge.pending(center),
                   !notificationRefreshRequested, token == generation, revision == notificationSettingsRevision {
                    pendingReminderIDs = Set(pending.map(\.identifier).filter { $0.hasPrefix("reminder.") })
                }
            } while notificationRefreshRequested
        }
    }

    private func content(for meeting: Meeting, reminder: Bool = false) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(meeting.title.prefix(256))
        content.body = meeting.start.formatted(date: .abbreviated, time: .shortened) +
            (meeting.location.isEmpty ? "" : " · " + String(meeting.location.prefix(100)))
        content.sound = .default
        content.categoryIdentifier = reminder ? (meeting.joinURL == nil ? "REMINDER" : "REMINDER_JOIN") : "MEETING"
        content.threadIdentifier = stableHash(meeting.seriesID)
        content.userInfo = ["meetingID": meeting.sourceID, "account": owner(of: meeting)]
        // Keep notification payloads small even when descriptions contain long HTML or attachments.
        // The full details are resolved by ID from the local cache when the user opens the alert.
        let fallback = Meeting(id: meeting.sourceID, seriesID: meeting.sourceSeriesID, calendarID: meeting.sourceCalendarID,
            calendarName: String(meeting.calendarName.prefix(128)), title: String(meeting.title.prefix(512)),
            start: meeting.start, end: meeting.end, allDay: meeting.allDay, details: "",
            location: String(meeting.location.prefix(256)), link: meeting.joinURL,
            attendees: [], organizer: "", cancelled: meeting.cancelled, allDayDates: meeting.allDayDates)
        if let data = try? JSONEncoder().encode(fallback), data.count < 12_000,
           let snapshot = String(data: data, encoding: .utf8) { content.userInfo["meeting"] = snapshot }
        return content
    }

    private func alert(_ change: MeetingChange) async throws {
        let entry = ActivityEntry(change: change)
        let content = content(for: change.meeting)
        content.subtitle = entry.title
        if change.kind == .changed { content.body = entry.summary() }
        let request = UNNotificationRequest(identifier: "change." + stableHash(entry.id), content: content, trigger: nil)
        try await NotificationBridge.add(request, to: center)
    }

    private func scheduleReminders() async throws {
        let token = generation, revision = notificationSettingsRevision
        let pending = try await NotificationBridge.pending(center)
        guard token == generation, revision == notificationSettingsRevision else { return }
        let now = Date()
        let plans = activeProfiles.flatMap { config -> [PlannedReminder] in
            guard let state = accountData[config.login] else { return [] }
            let pool = mergedMeetings(state.meetings + state.personal.snoozes.map(\.meeting))
            return ReminderPlanner.plan(meetings: pool, state: state.personal, defaults: config.reminderMinutes,
                calendarIDs: Set(config.calendarIDs), account: config.login, now: now)
                .map { $0.scoped(to: config.login) }
        }.sorted { $0.date == $1.date ? $0.key < $1.key : $0.date < $1.date }.prefix(60)
        let wanted = Set(plans.map(reminderIdentifier))
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.identifier.hasPrefix("reminder.") && !wanted.contains($0.identifier)
        }.map(\.identifier))
        let existing = Set(pending.map(\.identifier))
        let deadline = Date().addingTimeInterval(20)
        for plan in plans {
            let id = reminderIdentifier(plan)
            guard !existing.contains(id) else { continue }
            guard token == generation, revision == notificationSettingsRevision else { return }
            guard Date() < deadline else { throw CalendarError.message("Очередь напоминаний будет дополнена при следующей проверке.") }
            let content = content(for: plan.meeting, reminder: true)
            content.subtitle = plan.snoozed ? "Вы просили напомнить" : "До начала: \(plan.minutes ?? 0) мин."
            let interval = plan.date.timeIntervalSinceNow
            guard interval > 1 else { continue }
            try await NotificationBridge.add(UNNotificationRequest(identifier: id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)), to: center)
            if token != generation || revision != notificationSettingsRevision {
                center.removePendingNotificationRequests(withIdentifiers: [id]); return
            }
        }
        guard token == generation, revision == notificationSettingsRevision else { return }
        try await scheduleOverview(pending: pending, generation: token, revision: revision)
        Self.notificationLogger.debug("Reminders reconciled, planned: \(plans.count, privacy: .public)")
        let delivered = try await NotificationBridge.delivered(center)
        let current = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let obsolete = delivered.filter { notification in
            guard notification.request.identifier.hasPrefix("reminder."),
                  let id = notification.request.content.userInfo["meetingID"] as? String,
                  let login = notification.request.content.userInfo["account"] as? String else { return false }
            if !activeAccountLogins.contains(login) { return true }
            if let meeting = current[CalendarAccountIdentity.scoped(id, to: login)] {
                let old = (notification.request.content.userInfo["meeting"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Meeting.self, from: $0) }
                return meeting.cancelled || meeting.end < Date() || (old != nil && (old!.start != meeting.start || old!.end != meeting.end || old!.joinURL != meeting.joinURL))
            }
            return false
        }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: obsolete)
    }

    private func reminderIdentifier(_ plan: PlannedReminder) -> String {
        "reminder." + stableHash(plan.key)
    }

    private func scheduleOverview(pending: [UNNotificationRequest], generation token: Int, revision: Int) async throws {
        overviewTimer?.invalidate()
        overviewTimer = nil
        let calendar = CalendarDates.calendar
        let prior = pending.map(\.identifier).filter { $0.hasPrefix("overview.") }
        guard activeAccountLogins.contains(configuration.login), configuration.dailyOverviewEnabled,
              let fire = configuration.nextDailyOverview(after: Date(), calendar: calendar) else {
            center.removePendingNotificationRequests(withIdentifiers: prior)
            return
        }
        let day = calendar.startOfDay(for: fire)
        let id = "overview." + CalendarDates.text(day, "yyyyMMdd")
        center.removePendingNotificationRequests(withIdentifiers: prior.filter { $0 != id })
        let overview = overview(on: day, from: upcoming)
        let content = UNMutableNotificationContent(); content.title = "Ваш день в CalendarBar"
        content.body = "Встреч: \(overview.meetings.count) · занято: \(overview.busyMinutes) мин. · пересечений: \(overview.conflicts.count)"
        content.categoryIdentifier = "OVERVIEW"; content.sound = .default
        content.userInfo = ["day": day.timeIntervalSince1970]
        try await NotificationBridge.add(UNNotificationRequest(identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSinceNow), repeats: false)), to: center)
        if token != generation || revision != notificationSettingsRevision {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        // Prepare the next overview from the cache even when network checks are paused.
        let timer = Timer(fire: fire.addingTimeInterval(2), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.updateNotifications() }
        }
        overviewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func testNotification() async {
        guard await requestNotifications() else { return }
        let content = UNMutableNotificationContent()
        content.title = "CalendarBar работает"
        content.body = "Так будут выглядеть напоминания о встречах."
        content.sound = .default
        do {
            try await NotificationBridge.add(UNNotificationRequest(identifier: "test", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)), to: center)
            Self.notificationLogger.info("Test notification scheduled")
            notificationStatus = "Тестовое уведомление запланировано через 3 секунды."
        } catch {
            Self.notificationLogger.error("Test notification scheduling failed")
            notificationStatus = NotificationBridge.message(for: error)
        }
    }
}

extension AppModel {
    var activeProfiles: [Configuration] { accounts.filter { activeAccountLogins.contains($0.login) } }
    var calendars: [CalendarInfo] { activeProfiles.flatMap { accountCalendars($0.login) } }
    var meetings: [Meeting] {
        activeProfiles.flatMap { config in (accountData[config.login]?.meetings ?? []).map { scoped($0, to: config.login) } }
    }
    var listedCalendarIDs: Set<String> { Set(calendars.filter(isCalendarListed).map(\.id)) }
    var visibleCalendarIDs: Set<String> {
        Set(calendars.filter { calendar in
            guard let login = calendar.accountLogin, isAccountVisible(login) else { return false }
            let state = accountData[login]?.personal ?? PersonalCalendarState()
            return !state.hiddenCalendars.contains(calendar.sourceID) && !state.filteredCalendars.contains(calendar.sourceID)
        }.map(\.id))
    }
    var notifyingCalendarIDs: Set<String> {
        Set(activeProfiles.flatMap { config in config.calendarIDs.map { CalendarAccountIdentity.scoped($0, to: config.login) } })
    }

    private func profile(for login: String) -> Configuration? {
        login == configuration.login ? configuration : accounts.first { $0.login == login }
    }
    private func owner(of meeting: Meeting) -> String { meeting.accountLogin ?? configuration.login }
    private func scoped(_ meeting: Meeting, to login: String) -> Meeting {
        let name = activeAccountLogins.count > 1 ? accountName(login) + " · " + meeting.sourceCalendarName : nil
        return meeting.scoped(to: login, calendarName: name)
    }
    func accountCalendars(_ login: String) -> [CalendarInfo] {
        (accountData[login]?.calendars ?? []).map { $0.scoped(to: login) }
    }
    private func calendar(withID id: String) -> CalendarInfo? {
        accounts.lazy.flatMap { self.accountCalendars($0.login) }.first { $0.id == id }
    }
    func isCalendarListed(_ calendar: CalendarInfo) -> Bool {
        !(accountData[calendar.accountLogin ?? configuration.login]?.personal.hiddenCalendars.contains(calendar.sourceID) ?? false)
    }
    func isCalendarNotifying(_ calendar: CalendarInfo) -> Bool {
        profile(for: calendar.accountLogin ?? configuration.login)?.calendarIDs.contains(calendar.sourceID) ?? false
    }
    func isCalendarEventsEnabled(_ calendar: CalendarInfo) -> Bool {
        isCalendarListed(calendar) &&
            !(accountData[calendar.accountLogin ?? configuration.login]?.personal.filteredCalendars.contains(calendar.sourceID) ?? false)
    }
    func accountLabel(_ login: String) -> String { accountLabels[login] ?? "" }
    func accountName(_ login: String) -> String { accountLabels[login] ?? login }
    func accountSyncIssue(_ login: String) -> String? { accountData[login]?.warning }
    func setAccountLabel(_ label: String, for login: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        accountLabels[login] = label.isEmpty ? nil : label
        persistAccountPreferences()
        calendarMeetings = calendarMeetings.map { scoped($0, to: owner(of: $0)) }
        searchResults = searchResults.map { scoped($0, to: owner(of: $0)) }
        if let meeting = standaloneMeeting { standaloneMeeting = scoped(meeting, to: owner(of: meeting)) }
        updateSyncWarning()
    }
    func isAccountVisible(_ login: String) -> Bool {
        activeAccountLogins.contains(login) && !hiddenAccounts.contains(login)
    }
    func setAccountVisible(_ login: String, visible: Bool) {
        if visible { hiddenAccounts.remove(login) } else { hiddenAccounts.insert(login) }
        persistAccountPreferences()
    }
    func setAccountActive(_ login: String, active: Bool) {
        guard !requestInFlight, !login.isEmpty, let profile = profile(for: login),
              activeAccountLogins.contains(login) != active else { return }
        if active {
            activeAccountLogins.insert(login)
            if !activeAccountLogins.contains(configuration.login) { configuration = profile }
        } else {
            activeAccountLogins.remove(login)
            Vault.clearSession(for: login)
            if configuration.login == login, let next = activeProfiles.first { configuration = next }
        }
        persistConfiguration()
        persistAccountPreferences()
        invalidateAccountPresentation()
        if active { queueSync(for: login) }
    }
    private func invalidateAccountPresentation() {
        generation += 1
        notificationSettingsRevision &+= 1
        calendarLoadID = UUID()
        searchID = UUID()
        calendarLoading = false
        searchLoading = false
        searchResults.removeAll { !activeAccountLogins.contains(owner(of: $0)) }
        if let meeting = standaloneMeeting, !activeAccountLogins.contains(owner(of: meeting)) { standaloneMeeting = nil }
        lastSync = activeProfiles.compactMap { accountData[$0.login]?.lastSync }.min()
        if activeProfiles.isEmpty { connectionState = .notConnected }
        else if connectionState == .notConnected { connectionState = .saved }
        updateSyncWarning()
        publishDisplayedRange(fromCache: true)
        scheduleBackgroundSync()
        updateNotifications()
    }
    private func updateSyncWarning() {
        syncWarning = activeProfiles.compactMap { config in
            accountData[config.login]?.warning.map { accountName(config.login) + " · " + $0 }
        }.joined(separator: "\n")
        if syncWarning?.isEmpty == true { syncWarning = nil }
    }
    var unreadChanges: Int {
        activeProfiles.reduce(0) { $0 + (accountData[$1.login]?.personal.activity.filter { !$0.read }.count ?? 0) }
    }

    var readinessText: String {
        if CalendarBarIdentity.isDemo { return connectionState.title }
        if activeProfiles.isEmpty { return accounts.isEmpty ? "Подключите аккаунт" : "Включите аккаунт в настройках" }
        if connectionState == .checking { return "Проверяю подключение…" }
        if connectionState == .unavailable { return "Нет свежих данных · показан кэш" }
        if syncWarning != nil { return "Расписание обновлено частично" }
        let now = Date()
        guard let interval = refreshSchedule.interval(at: now, calendar: CalendarDates.calendar) else {
            return "Фоновое обновление приостановлено"
        }
        guard let lastSync else { return "Ожидаю первую загрузку" }
        if now.timeIntervalSince(lastSync) > interval.seconds * 3 {
            return "Данные давно не обновлялись · показан кэш"
        }
        if notificationAuthorization == nil || notificationAuthorization == .denied || notificationAuthorization == .notDetermined { return "Встречи загружены · настройте уведомления" }
        if notifyingCalendarIDs.isEmpty { return "Выберите календари для уведомлений" }
        return "Календарь обновлён"
    }
    func includeCalendar(_ id: String, included: Bool) {
        guard let calendar = calendar(withID: id), let login = calendar.accountLogin,
              isCalendarListed(calendar) != included else { return }
        accountData[login]?.personal.includeCalendar(calendar.sourceID, included: included)
        persistPersonal(for: login)
        if included && activeAccountLogins.contains(login) { queueSync(for: login) }
    }
    func showCalendarEvents(_ id: String, visible: Bool) {
        guard let calendar = calendar(withID: id), let login = calendar.accountLogin, isCalendarListed(calendar) else { return }
        accountData[login]?.personal.showCalendarEvents(calendar.sourceID, visible: visible)
        persistPersonal(for: login)
    }
    func setHour(_ key: WritableKeyPath<Configuration, Int>, value: Int) {
        configuration[keyPath: key] = min(max(value, key == \.workdayEndHour ? 1 : 0), key == \.workdayEndHour ? 24 : 23)
        if configuration.workdayEndHour <= configuration.workdayStartHour {
            if key == \.workdayEndHour { configuration.workdayStartHour = configuration.workdayEndHour - 1 }
            else { configuration.workdayEndHour = configuration.workdayStartHour + 1 }
        }
        persistConfiguration(); notificationSettingsRevision &+= 1; updateNotifications()
        scheduleBackgroundSync()
    }
    func setDailyOverviewTime(hour: Int, minute: Int) {
        guard hour != configuration.dailyOverviewHour || minute != configuration.dailyOverviewMinute else { return }
        configuration.dailyOverviewHour = hour
        configuration.dailyOverviewMinute = minute
        notificationSettingsRevision &+= 1
        persistConfiguration()
        updateNotifications()
    }
    func overview(on day: Date, from events: [Meeting]? = nil, includeConflicts: Bool = true) -> DayOverview {
        DayOverview.make(meetings: (events ?? calendarMeetings.filter { visibleCalendarIDs.contains($0.calendarID) }).map(displayedMeeting),
            day: day, calendar: CalendarDates.calendar, account: configuration.login,
            startHour: configuration.workdayStartHour, endHour: configuration.workdayEndHour,
            includeConflicts: includeConflicts)
    }

    func planningSlots(on day: Date, from displayedEvents: [Meeting]) -> [Range<Date>] {
        DayOverview.make(meetings: displayedEvents, day: day, calendar: CalendarDates.calendar,
            account: configuration.login, startHour: configuration.workdayStartHour,
            endHour: configuration.workdayEndHour, minimumMinutes: 1, includeConflicts: false,
            blockAllTimedEvents: true).freeSlots
    }
    private func mergedMeetings(_ events: [Meeting]) -> [Meeting] {
        Array(Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
    }
    func currentMeeting(id: String) -> Meeting? {
        (meetings + calendarMeetings + searchResults + activeSnoozes.map(\.meeting)).first { $0.id == id }
    }

    private func recordActivity(_ changes: [MeetingChange], in state: inout PersonalCalendarState) {
        var ids = Set(state.activity.map(\.id))
        for change in changes {
            let entry = ActivityEntry(change: change)
            if ids.insert(entry.id).inserted { state.activity.insert(entry, at: 0) }
        }
        state.activity = Array(state.activity.prefix(200))
    }

    var activeActivity: [(id: String, login: String, entry: ActivityEntry)] {
        activeProfiles.flatMap { config in
            (accountData[config.login]?.personal.activity ?? []).map {
                (CalendarAccountIdentity.scoped($0.id, to: config.login), config.login, $0)
            }
        }.sorted { $0.entry.date > $1.entry.date }
    }

    var activeSnoozes: [SnoozedReminder] {
        activeProfiles.flatMap { config in
            (accountData[config.login]?.personal.snoozes ?? []).map {
                SnoozedReminder(meeting: scoped($0.meeting, to: config.login), fireAt: $0.fireAt)
            }
        }
    }

    func markChangesRead() {
        for config in activeProfiles {
            let login = config.login
            guard var state = accountData[login]?.personal else { continue }
            for i in state.activity.indices { state.activity[i].read = true }
            accountData[login]?.personal = state
            persistPersonal(for: login)
        }
    }
    func readActivity(_ id: String, login: String) {
        if let i = accountData[login]?.personal.activity.firstIndex(where: { $0.id == id }) {
            accountData[login]?.personal.activity[i].read = true
            persistPersonal(for: login)
        }
    }
    func activityMeeting(_ meeting: Meeting, login: String) -> Meeting { scoped(meeting, to: login) }

    func activateAccount(_ login: String) async {
        guard !requestInFlight, login != configuration.login, let profile = profile(for: login),
              activeAccountLogins.contains(login) else { return }
        configuration = profile
        persistConfiguration()
        scheduleBackgroundSync()
        notificationSettingsRevision &+= 1
        updateNotifications()
    }
    func clearActivity() {
        for config in activeProfiles {
            accountData[config.login]?.personal.activity = []
            persistPersonal(for: config.login)
        }
    }
    @discardableResult
    private func persistPersonal(for login: String) -> Bool {
        guard !CalendarBarIdentity.isDemo else { return true }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = Self.personalURL(login)
            try JSONEncoder().encode(accountData[login]?.personal ?? PersonalCalendarState()).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            message = "Не удалось сохранить личные настройки: " + error.localizedDescription
            return false
        }
    }
    func personalState(for meeting: Meeting) -> PersonalCalendarState {
        accountData[owner(of: meeting)]?.personal ?? PersonalCalendarState()
    }
    func reminderDefaults(for meeting: Meeting) -> [Int] {
        profile(for: owner(of: meeting))?.reminderMinutes ?? configuration.reminderMinutes
    }
    func reminderSettings(for meeting: Meeting) -> ReminderOverride? { personalState(for: meeting).settings(for: meeting.unscoped()) }
    func reminderOverride(for meeting: Meeting, scope: EventScope) -> ReminderOverride? {
        let key = scope == .series ? "series:" + meeting.sourceSeriesID : meeting.sourceID
        return personalState(for: meeting).overrides[key]
    }

    func remindersEnabledForCalendar(of meeting: Meeting) -> Bool {
        let login = owner(of: meeting)
        return activeAccountLogins.contains(login) && profile(for: login)?.calendarIDs.contains(meeting.sourceCalendarID) == true
    }

    func nextScheduledReminder(for meeting: Meeting, at now: Date) -> PlannedReminder? {
        let login = owner(of: meeting)
        guard let pendingReminderIDs, remindersEnabledForCalendar(of: meeting),
              let config = profile(for: login) else { return nil }
        let plans = ReminderPlanner.plan(meetings: [meeting.unscoped()], state: personalState(for: meeting),
            defaults: config.reminderMinutes, calendarIDs: Set(config.calendarIDs), account: login, now: now)
        return plans.map { $0.scoped(to: login) }.first { pendingReminderIDs.contains(reminderIdentifier($0)) }
    }

    func setReminderOverride(for meeting: Meeting, scope: EventScope, value: ReminderOverride?) {
        let login = owner(of: meeting)
        guard activeAccountLogins.contains(login), var state = accountData[login]?.personal else { return }
        let key = scope == .series ? "series:" + meeting.sourceSeriesID : meeting.sourceID
        state.overrides[key] = value
        if scope == .series {
            state.overrides = state.overrides.filter { item in
                guard !item.key.hasPrefix("series:"), let separator = item.key.lastIndex(of: "|") else { return true }
                return String(item.key[..<separator]) != meeting.sourceSeriesID
            }
        }
        state.snoozes.removeAll { $0.id == meeting.sourceID || (scope == .series && $0.meeting.seriesID == meeting.sourceSeriesID) }
        accountData[login]?.personal = state
        notificationSettingsRevision &+= 1
        persistPersonal(for: login)
        updateNotifications()
        removeDelivered(for: meeting)
    }
    @discardableResult func snooze(_ meeting: Meeting, until date: Date) -> Bool {
        let login = owner(of: meeting)
        guard activeAccountLogins.contains(login), var state = accountData[login]?.personal else { return false }
        let current = (currentMeeting(id: meeting.id) ?? meeting).unscoped()
        guard !current.cancelled, !current.allDay, date > Date().addingTimeInterval(1), date < current.end else {
            message = "Выберите время до окончания встречи."; return false
        }
        state.snoozes.removeAll { $0.id == current.id }
        state.snoozes.append(SnoozedReminder(meeting: current, fireAt: date))
        if state.settings(for: current)?.muted == true { state.overrides[current.id] = ReminderOverride(minutes: []) }
        accountData[login]?.personal = state
        notificationSettingsRevision &+= 1
        persistPersonal(for: login)
        updateNotifications()
        removeDelivered(for: meeting)
        return true
    }
    private func removeDelivered(for meeting: Meeting) {
        guard !CalendarBarIdentity.isDemo else { return }
        let login = owner(of: meeting)
        Task {
            if let notifications = try? await NotificationBridge.delivered(center) {
                center.removeDeliveredNotifications(withIdentifiers: notifications.filter {
                    $0.request.content.userInfo["meetingID"] as? String == meeting.sourceID &&
                    $0.request.content.userInfo["account"] as? String == login
                }.map { $0.request.identifier })
            }
        }
    }
    func cancelSnooze(_ meeting: Meeting) {
        let login = owner(of: meeting)
        accountData[login]?.personal.snoozes.removeAll { $0.id == meeting.sourceID }
        persistPersonal(for: login)
        notificationSettingsRevision &+= 1
        updateNotifications()
    }
    func showStandaloneMeeting(_ meeting: Meeting) {
        standaloneMeeting = meeting
    }
    func focusInCalendar(_ meeting: Meeting) {
        setAccountVisible(owner(of: meeting), visible: true)
        if !listedCalendarIDs.contains(meeting.calendarID) { includeCalendar(meeting.calendarID, included: true) }
        showCalendarEvents(meeting.calendarID, visible: true)
        let current = currentMeeting(id: meeting.id) ?? meeting
        calendarNavigation = CalendarNavigationRequest(destination: .meeting(current))
        AppWindows.showCalendar()
    }
    func openInYandex(_ meeting: Meeting? = nil) {
        guard !CalendarBarIdentity.isDemo else { return }
        let url = meeting.map { YandexCalendarLinks.event(displayedMeeting($0), timeZone: CalendarDates.calendar.timeZone) } ?? YandexCalendarLinks.home
        NSWorkspace.shared.open(url)
    }
    func createInYandex(at date: Date, end: Date? = nil) {
        guard !CalendarBarIdentity.isDemo else { return }
        NSWorkspace.shared.open(YandexCalendarLinks.create(start: date, end: end, timeZone: CalendarDates.calendar.timeZone))
    }
    func searchMeetings(range: Range<Date>) async {
        let id = UUID()
        searchID = id; searchLoading = true; searchError = ""
        let profiles = activeProfiles
        searchResults = profiles.flatMap { config in
            cachedMeetings(for: config.login, range: range).map { scoped($0, to: config.login) }
        }
        defer { if searchID == id { searchLoading = false } }
        guard range.upperBound.timeIntervalSince(range.lowerBound) <= 3 * 366 * 86400 else {
            searchError = "Выберите период не длиннее трёх лет."; return
        }
        guard !CalendarBarIdentity.isDemo else { return }
        while requestInFlight {
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard searchID == id, !Task.isCancelled else { return }
        }
        guard searchID == id, !Task.isCancelled else { return }
        requestInFlight = true; busy = true
        defer { requestInFlight = false; busy = false; progress = "" }
        var issues: [String] = []
        for config in profiles {
            let login = config.login
            do {
                let batch = try await fetchAccount(config, range: range, kind: .search) { self.searchID == id }
                guard searchID == id, !Task.isCancelled else { return }
                let results = meetingsFromBatch(batch, retaining: cachedMeetings(for: login, range: range), in: range, login: login)
                searchResults.removeAll { $0.accountLogin == login }
                searchResults += results.map { scoped($0, to: login) }
                if let warning = batch.warning { issues.append(accountName(login) + " · " + warning) }
                try? saveResources(for: login)
            } catch is CancellationError { return }
            catch { issues.append(accountName(login) + " · " + error.localizedDescription) }
        }
        if searchID == id { searchError = issues.joined(separator: "\n") }
    }
    func handleNotification(_ response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDismissActionIdentifier { return }
        if let day = info["day"] as? Double {
            calendarNavigation = CalendarNavigationRequest(destination: .day(Date(timeIntervalSince1970: day)))
            AppWindows.showCalendar()
            return
        }
        guard let login = info["account"] as? String, activeAccountLogins.contains(login) else { return }
        let snapshot = (info["meeting"] as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Meeting.self, from: $0) }
        guard let id = info["meetingID"] as? String, let meeting = currentMeeting(id: CalendarAccountIdentity.scoped(id, to: login)) ?? snapshot.map({ scoped($0, to: login) }) else { AppWindows.showCalendar(); return }
        switch response.actionIdentifier {
        case "JOIN":
            if !meeting.cancelled, meeting.end > Date(), let url = meeting.joinURL { MeetingLinkOpener.open(url) }
            else { AppWindows.showMeeting(meeting) }
        case "SNOOZE5":
            if !snooze(meeting, until: Date().addingTimeInterval(300)) { AppWindows.showMeeting(meeting) }
        case "AT_START":
            if !snooze(meeting, until: meeting.start) { AppWindows.showMeeting(meeting) }
        case "MUTE": setReminderOverride(for: meeting, scope: .occurrence, value: ReminderOverride(muted: true))
        default: AppWindows.showMeeting(meeting)
        }
    }
}

extension AppModel {
    func displayedMeeting(_ meeting: Meeting) -> Meeting {
        let zone = profile(for: owner(of: meeting)).flatMap { TimeZone(identifier: $0.zone) } ?? .current
        return meeting.displayed(in: CalendarDates.calendar, fallbackZone: zone)
    }

    func calendarTint(for id: String) -> CalendarTint? {
        guard let calendar = calendar(withID: id), let login = calendar.accountLogin else { return nil }
        return accountData[login]?.personal.calendarTint(for: calendar.sourceID)
    }

    func setCalendarTint(_ tint: CalendarTint?, for id: String) {
        guard let calendar = calendar(withID: id), let login = calendar.accountLogin else { return }
        accountData[login]?.personal.setCalendarTint(tint, for: calendar.sourceID)
        persistPersonal(for: login)
    }

    func meetingTint(for meeting: Meeting, scope: EventScope? = nil) -> CalendarTint? {
        personalState(for: meeting).meetingTint(for: meeting, scope: scope)
    }

    func setMeetingTint(_ tint: CalendarTint?, for meeting: Meeting, scope: EventScope) {
        let login = owner(of: meeting)
        accountData[login]?.personal.setMeetingTint(tint, for: meeting, scope: scope)
        persistPersonal(for: login)
    }

    func isPinned(_ meeting: Meeting) -> Bool {
        meeting.joinURL.map(personalState(for: meeting).isPinned) ?? false
    }

    @discardableResult func togglePinned(_ meeting: Meeting) -> Bool {
        guard let url = meeting.joinURL else { return false }
        let login = owner(of: meeting)
        guard activeAccountLogins.contains(login) else { return false }
        let previous = personalState(for: meeting)
        var updated = previous
        updated.togglePin(title: meeting.title, url: url)
        guard updated.isPinned(url) != previous.isPinned(url) else { return false }
        accountData[login, default: AccountData()].personal = updated
        guard persistPersonal(for: login) else {
            accountData[login]?.personal = previous
            return false
        }
        return true
    }

    var menuPins: [PinnedMeeting] {
        let logins = activeProfiles.isEmpty ? [configuration.login] : activeProfiles.map(\.login)
        var seen = Set<URL>()
        return logins.flatMap(pins).filter { seen.insert($0.id).inserted }
    }

    func pins(for login: String) -> [PinnedMeeting] {
        accountData[login]?.personal.pinnedMeetings ?? []
    }

    func removePinned(_ pin: PinnedMeeting, for login: String) {
        accountData[login]?.personal.removePin(pin.id)
        persistPersonal(for: login)
    }

    func savePinned(_ pin: PinnedMeeting, replacing id: URL?, for login: String) -> Bool {
        let previous = accountData[login]?.personal ?? PersonalCalendarState()
        guard accountData[login, default: AccountData()].personal.savePin(pin, replacing: id) else { return false }
        guard persistPersonal(for: login) else {
            accountData[login]?.personal = previous
            return false
        }
        return true
    }

    func movePinned(_ pin: PinnedMeeting, by offset: Int, for login: String) {
        if accountData[login]?.personal.movePin(pin.id, by: offset) == true { persistPersonal(for: login) }
    }

    func hideLastMeeting(_ meeting: Meeting) {
        let login = owner(of: meeting)
        accountData[login, default: AccountData()].personal.hiddenLastMeeting = FinishedMeetingReference(meeting.unscoped())
        persistPersonal(for: login)
    }

    func showLastMeeting(_ meeting: Meeting) {
        let login = owner(of: meeting)
        accountData[login]?.personal.hiddenLastMeeting = nil
        persistPersonal(for: login)
    }

    func hiddenLastMeeting(for last: Meeting?) -> FinishedMeetingReference? {
        guard let last, let hidden = personalState(for: last).hiddenLastMeeting else { return nil }
        if hidden == FinishedMeetingReference(last.unscoped()) {
            return FinishedMeetingReference(last)
        }
        return hidden
    }
}
