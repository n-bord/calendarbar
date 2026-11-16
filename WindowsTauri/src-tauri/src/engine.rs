use crate::{
    calendar::{displayed, scoped_id, Meeting},
    dav::YandexCalendarClient,
    model::{background_range, day_at, display_zone, now, Activity, Bounds, Disk, Profile, Range},
    platform,
};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    sync::{Mutex, MutexGuard},
};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Clone, Default)]
pub struct Navigation {
    pub meeting: Option<String>,
    pub date: Option<i64>,
    pub query: Option<String>,
    pub token: u64,
}

pub struct Runtime {
    pub disk: Disk,
    pub busy: bool,
    pub sync_message: String,
    pub notification_status: String,
    waiting: BTreeMap<String, Range>,
    navigation: BTreeMap<String, Navigation>,
    cache_revisions: BTreeMap<String, u64>,
    revision: u64,
    pub last_reminder_check: i64,
}

impl Runtime {
    pub fn update_view(&mut self, view: &str, range: Range) {
        self.waiting.insert(view.into(), range);
    }
    pub fn remove_view(&mut self, view: &str) {
        self.waiting.remove(view);
        self.navigation.remove(view);
    }
    pub fn set_navigation(&mut self, view: &str, mut nav: Navigation) {
        if nav.meeting.is_none() && nav.date.is_none() && nav.query.is_none() {
            return;
        }
        self.revision += 1;
        nav.token = self.revision;
        self.navigation.insert(view.into(), nav);
    }
    pub fn reset_cache_focus(&mut self, accounts: &BTreeSet<String>) {
        for login in accounts {
            *self.cache_revisions.entry(login.clone()).or_default() += 1;
        }
        let prefixes: Vec<_> = accounts.iter().map(|login| scoped_id("", login)).collect();
        for nav in self.navigation.values_mut() {
            if nav
                .meeting
                .as_ref()
                .is_some_and(|id| prefixes.iter().any(|prefix| id.starts_with(prefix)))
            {
                self.revision += 1;
                *nav = Navigation {
                    token: self.revision,
                    ..Navigation::default()
                };
            }
        }
    }

    pub fn snapshot(&self, view: &str) -> Value {
        let disk = &self.disk;
        let at = now();
        let zone = display_zone();
        let nav = self.navigation.get(view);
        let focus = nav
            .and_then(|nav| nav.meeting.as_deref())
            .and_then(|id| disk.event(id))
            .cloned()
            .map(|event| displayed(event, zone));
        let range = match view {
            "tray" => Some(background_range(at)),
            "calendar" => self.waiting.get(view).copied().or_else(|| {
                Some(Range {
                    from: day_at(at, -7, 0, 0),
                    to: day_at(at, 8, 0, 0),
                })
            }),
            "search" => self.waiting.get(view).copied(),
            _ => None,
        };
        let mut meetings: Vec<Meeting> = match range {
            Some(range) => disk
                .active()
                .flat_map(Profile::meetings)
                .filter(|event| range.includes(event))
                .cloned()
                .map(|event| displayed(event, zone))
                .collect(),
            None => Vec::new(),
        };
        if let Some(event) = &focus {
            if !meetings.iter().any(|item| item.id == event.id) {
                meetings.push(event.clone());
            }
        }
        meetings.sort_unstable_by(|a, b| (a.start, a.end, &a.id).cmp(&(b.start, b.end, &b.id)));
        let accounts: Vec<Value> = disk.accounts.iter().map(|account| json!({
            "login": account.login, "label": account.label, "active": account.active, "visible": account.visible,
            "settings": account.settings, "calendars": account.calendars, "error": account.error
        })).collect();
        let mut settings = json!(disk.preferences());
        if let (Some(settings), Value::Object(globals)) =
            (settings.as_object_mut(), json!(disk.globals))
        {
            settings.extend(globals);
        }
        let mut activity: Vec<_> = disk
            .active()
            .flat_map(|account| account.activity.iter())
            .collect();
        activity.sort_unstable_by_key(|item| std::cmp::Reverse(item.at));
        let activity = if view == "activity" {
            json!(activity)
        } else {
            json!(activity
                .into_iter()
                .map(|item| json!({"id": item.id, "unread": item.unread}))
                .collect::<Vec<_>>())
        };
        let reminders = if matches!(view, "calendar" | "meeting" | "search") {
            json!(disk
                .active()
                .flat_map(|profile| profile.reminders.iter())
                .collect::<BTreeMap<_, _>>())
        } else {
            json!({})
        };
        let colors = if matches!(view, "calendar" | "meeting" | "search") {
            json!(disk
                .active()
                .flat_map(|profile| profile.colors.iter())
                .collect::<BTreeMap<_, _>>())
        } else {
            json!({})
        };
        let mut result = json!({
            "version": env!("CARGO_PKG_VERSION"), "appearance": disk.globals.appearance, "settings": settings,
            "accounts": accounts, "primaryLogin": disk.primary_login, "meetings": meetings,
            "focusMeeting": focus, "focusToken": nav.map_or(0, |nav| nav.token),
            "cacheRevisions": self.cache_revisions, "activity": activity, "reminders": reminders, "colors": colors,
            "pins": disk.active().flat_map(|profile| profile.pins.iter()).chain(disk.local_pins.iter()).collect::<Vec<_>>(),
            "snoozes": disk.active().flat_map(|profile| profile.snoozes.iter()).collect::<Vec<_>>(),
            "hiddenLast": disk.active().map(|profile| (&profile.login, &profile.hidden_last)).collect::<BTreeMap<_,_>>(),
            "syncing": self.busy, "warning": disk.warning(), "lastSync": disk.last_sync(), "coverage": disk.coverage(),
            "now": at, "syncMessage": self.sync_message, "notificationStatus": self.notification_status
        });
        if view == "settings" {
            result["cacheBytes"] = json!(disk
                .accounts
                .iter()
                .map(|profile| (&profile.login, profile.cache_bytes()))
                .collect::<BTreeMap<_, _>>());
        }
        if view == "pinned" {
            result["pins"] = json!(disk
                .accounts
                .iter()
                .flat_map(|profile| profile.pins.iter())
                .chain(disk.local_pins.iter())
                .collect::<Vec<_>>());
        }
        if let Some(date) = nav.and_then(|nav| nav.date) {
            result["focusDate"] = json!(date);
        }
        if let Some(query) = nav.and_then(|nav| nav.query.as_ref()) {
            result["focusQuery"] = json!(query);
        }
        result
    }
}

pub struct Engine {
    pub file: PathBuf,
    pub data: Mutex<Runtime>,
    network: tokio::sync::Mutex<()>,
    pub reminder_wakeup: tokio::sync::Notify,
}

impl Engine {
    pub fn open(file: PathBuf, legacy: Option<PathBuf>) -> Result<Self, String> {
        let disk = match Disk::read(&file)? {
            Some(disk) => disk,
            None => {
                let mut disk = Disk::default();
                if let Some(folder) = legacy {
                    if let Some(mut imported) = Disk::read(&folder.join("calendarbar.json"))? {
                        for account in &mut imported.accounts {
                            if let Some(ciphertext) = &account.password {
                                match platform::import_electron_password(
                                    ciphertext,
                                    &folder.join("Local State"),
                                ) {
                                    Ok(value) => account.password = Some(value),
                                    Err(_) => {
                                        account.password = None;
                                        account.error = "Введите пароль приложения заново в настройках подключения.".into();
                                    }
                                }
                            }
                        }
                        // The existing Electron startup item stays registered while the builds coexist.
                        imported.globals.auto_start = false;
                        disk = imported;
                    }
                }
                disk.save(&file)?;
                disk
            }
        };
        Ok(Self {
            file,
            network: tokio::sync::Mutex::new(()),
            reminder_wakeup: tokio::sync::Notify::new(),
            data: Mutex::new(Runtime {
                disk,
                busy: false,
                sync_message: String::new(),
                notification_status: "Системные уведомления".into(),
                waiting: BTreeMap::new(),
                navigation: BTreeMap::new(),
                cache_revisions: BTreeMap::new(),
                revision: 0,
                last_reminder_check: now(),
            }),
        })
    }

    pub fn lock(&self) -> MutexGuard<'_, Runtime> {
        self.data
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn set_busy(&self, busy: bool, message: &str) {
        let mut data = self.lock();
        data.busy = busy;
        data.sync_message = message.into();
    }

    pub fn persist(&self, data: &Runtime) -> Result<(), String> {
        data.disk.save(&self.file)
    }
}

pub fn publish(app: &AppHandle) {
    let engine = app.state::<Engine>();
    for (view, window) in app.webview_windows() {
        if window.is_visible().unwrap_or(false) {
            let snapshot = engine.lock().snapshot(&view);
            if let Err(error) = app.emit_to(&view, "calendarbar-update", snapshot) {
                eprintln!("{error}");
            }
        }
    }
}

fn account_is_current(profile: &Profile, login: &str, secret: &str, zone: &str) -> bool {
    profile.active
        && profile.login == login
        && profile.password.as_deref() == Some(secret)
        && profile.settings.zone == zone
}

pub async fn connect(app: &AppHandle, payload: &Value) -> Result<(), String> {
    let login = payload["login"]
        .as_str()
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    if login.matches('@').count() != 1
        || login.starts_with('@')
        || login.ends_with('@')
        || login.contains(':')
        || login.chars().any(char::is_whitespace)
    {
        return Err("Укажите полный рабочий e-mail.".into());
    }
    let zone = payload["zone"]
        .as_str()
        .filter(|value| !value.is_empty())
        .unwrap_or("Europe/Moscow");
    if zone.parse::<chrono_tz::Tz>().is_err() {
        return Err("Укажите часовой пояс, например Europe/Moscow.".into());
    }
    let engine = app.state::<Engine>();
    let guard = engine.network.lock().await;
    engine.set_busy(true, "Проверяю подключение к Яндексу…");
    publish(app);
    let result: Result<bool, String> = async {
        let supplied = payload["password"]
            .as_str()
            .filter(|value| !value.is_empty());
        let saved = engine
            .lock()
            .disk
            .account(&login)
            .and_then(|account| account.password.clone());
        let secret = match (supplied, &saved) {
            (Some(secret), _) => secret.to_owned(),
            (_, Some(ciphertext)) => platform::unprotect_password(ciphertext)?,
            _ => return Err("Введите пароль приложения Яндекс ID типа «Календарь».".into()),
        };
        let client = YandexCalendarClient::new(&login, &secret)?;
        let calendars = client.calendars().await?;
        let encrypted = match supplied {
            Some(_) => Some(platform::protect_password(&secret)?),
            None => saved.clone(),
        };
        let mut data = engine.lock();
        if data
            .disk
            .account(&login)
            .and_then(|account| account.password.clone())
            != saved
        {
            return Err("Аккаунт изменился. Повторите подключение.".into());
        }
        if data.disk.account(&login).is_none() {
            let settings = if data.disk.primary_login.is_empty() {
                data.disk.unlinked_settings.clone()
            } else {
                Default::default()
            };
            data.disk.accounts.push(Profile {
                login: login.clone(),
                settings,
                ..Profile::default()
            });
        }
        let account = data.disk.account_mut(&login)?;
        if account.settings.zone != zone {
            account.clear_cache(now());
        }
        account.settings.zone = zone.into();
        account.password = encrypted;
        if let Some(label) = payload["label"].as_str() {
            account.label = label.trim().chars().take(64).collect();
        }
        account.error.clear();
        account.merge_calendars(calendars);
        let active = account.active;
        data.disk.select_primary();
        engine.persist(&data)?;
        Ok(active)
    }
    .await;
    engine.set_busy(false, "");
    drop(guard);
    publish(app);
    if result? {
        spawn_refresh(app, Some(login));
    }
    Ok(())
}

async fn refresh_profile(
    engine: &Engine,
    login: &str,
    range: Range,
    background: bool,
    force: bool,
) -> Result<Vec<Activity>, String> {
    let (encrypted, zone) = {
        let mut data = engine.lock();
        let profile = data.disk.account_mut(login)?;
        if !profile.active {
            return Ok(Vec::new());
        }
        if background {
            profile.last_attempt = now();
        }
        (
            profile
                .password
                .clone()
                .ok_or("Введите пароль приложения Яндекса в настройках подключения.")?,
            profile.settings.zone.clone(),
        )
    };
    let pass = platform::unprotect_password(&encrypted)?;
    let client = YandexCalendarClient::new(login, &pass)?;
    let mut issues = Vec::new();
    if background {
        match client.calendars().await {
            Ok(calendars) => {
                let mut data = engine.lock();
                if let Some(profile) = data
                    .disk
                    .accounts
                    .iter_mut()
                    .find(|profile| account_is_current(profile, login, &encrypted, &zone))
                {
                    profile.merge_calendars(calendars);
                } else {
                    return Ok(Vec::new());
                }
            }
            Err(problem) => {
                let data = engine.lock();
                if !data
                    .disk
                    .account(login)
                    .is_some_and(|profile| !profile.calendars.is_empty())
                {
                    return Err(problem);
                }
                issues.push(problem);
            }
        }
    }
    let calendars = {
        let data = engine.lock();
        let Some(profile) = data
            .disk
            .account(login)
            .filter(|profile| account_is_current(profile, login, &encrypted, &zone))
        else {
            return Ok(Vec::new());
        };
        profile
            .calendars
            .iter()
            .filter(|calendar| calendar.listed || (background && calendar.notify))
            .cloned()
            .collect::<Vec<_>>()
    };
    let mut successful = BTreeSet::new();
    for calendar in calendars {
        let (resources, timezone) = {
            let data = engine.lock();
            let Some(profile) = data
                .disk
                .account(login)
                .filter(|profile| account_is_current(profile, login, &encrypted, &zone))
            else {
                return Ok(Vec::new());
            };
            let entry = profile.cache.get(&calendar.info.id);
            if !force
                && entry.is_some_and(|entry| entry.coverage.iter().any(|saved| saved.covers(range)))
            {
                continue;
            }
            (
                entry
                    .map(|cache| cache.resources.clone())
                    .unwrap_or_default(),
                profile.settings.tz(),
            )
        };
        let result = client
            .meetings(
                &calendar.info,
                range.from,
                range.to,
                &resources,
                timezone,
                display_zone(),
            )
            .await;
        let mut data = engine.lock();
        let Some(profile) = data
            .disk
            .accounts
            .iter_mut()
            .find(|profile| account_is_current(profile, login, &encrypted, &zone))
        else {
            return Ok(Vec::new());
        };
        match result {
            Ok(batch) => {
                if !batch.complete {
                    issues.push(format!(
                        "{} · часть встреч не загрузилась.",
                        calendar.info.name
                    ));
                }
                if batch.complete && calendar.notify {
                    successful.insert(calendar.info.id.clone());
                }
                profile.reconcile(&calendar.info.id, range, batch);
            }
            Err(problem) => issues.push(format!("{} · {problem}", calendar.info.name)),
        }
    }
    let mut data = engine.lock();
    let Some(profile) = data
        .disk
        .accounts
        .iter_mut()
        .find(|profile| account_is_current(profile, login, &encrypted, &zone))
    else {
        return Ok(Vec::new());
    };
    let changes = if background {
        profile.activity(range, &successful, now(), !issues.is_empty())
    } else {
        Vec::new()
    };
    profile.error = issues.join("\n");
    Ok(changes)
}

pub async fn refresh(
    app: &AppHandle,
    view: Option<&str>,
    range: Option<Range>,
    force: bool,
    logins: Option<Vec<String>>,
    skip_busy: bool,
) -> Result<(), String> {
    let engine = app.state::<Engine>();
    if let (Some(view), Some(range)) = (view, range) {
        engine.lock().update_view(view, range);
        // Update immediately from disk while waiting for CalDAV.
        publish(app);
    }
    let _guard = if skip_busy {
        match engine.network.try_lock() {
            Ok(guard) => guard,
            Err(_) => return Ok(()),
        }
    } else {
        engine.network.lock().await
    };
    let (selected, ready) = {
        let data = engine.lock();
        let selected = logins.unwrap_or_else(|| {
            data.disk
                .active()
                .map(|profile| profile.login.clone())
                .collect()
        });
        let ready = !force
            && range
                .is_some_and(|range| data.disk.coverage().iter().any(|item| item.covers(range)));
        (selected, ready)
    };
    if ready || selected.is_empty() {
        return Ok(());
    }
    engine.set_busy(true, "Обновляю расписание…");
    publish(app);
    let fetch_range = range.unwrap_or_else(|| background_range(now()));
    let result = async {
        let mut changes = Vec::new();
        for login in selected {
            match refresh_profile(&engine, &login, fetch_range, range.is_none(), force).await {
                Ok(batch) => changes.extend(batch),
                Err(error) => {
                    if let Ok(profile) = engine.lock().disk.account_mut(&login) {
                        profile.error = error;
                    }
                }
            }
            engine.persist(&engine.lock())?;
            publish(app);
        }
        for change in changes {
            crate::notifications::notify_change(app, &change);
        }
        Ok::<_, String>(())
    }
    .await;
    engine.set_busy(false, "");
    publish(app);
    crate::update_tray(app);
    engine.reminder_wakeup.notify_one();
    // A search can still display saved results from a partially loaded period.
    result?;
    if view == Some("search") {
        let data = engine.lock();
        let warnings = data.disk.warning();
        if !warnings.is_empty()
            && !data
                .disk
                .coverage()
                .iter()
                .any(|item| item.covers(fetch_range))
        {
            return Err(warnings);
        }
    }
    Ok(())
}

pub fn spawn_refresh(app: &AppHandle, login: Option<String>) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = refresh(
            &app,
            None,
            None,
            true,
            login.map(|login| vec![login]),
            false,
        )
        .await
        {
            eprintln!("{error}");
        }
    });
}

pub async fn refresh_if_due(app: &AppHandle) {
    let engine = app.state::<Engine>();
    let at = now();
    let due: Vec<String> = {
        let data = engine.lock();
        let interval = data.disk.refresh_interval(at);
        if interval <= 0 {
            return;
        }
        data.disk
            .active()
            .filter(|profile| {
                profile.password.is_some()
                    && (profile.last_attempt <= at - interval || profile.last_attempt > at)
            })
            .map(|profile| profile.login.clone())
            .collect()
    };
    if !due.is_empty() {
        if let Err(error) = refresh(app, None, None, true, Some(due), true).await {
            eprintln!("{error}");
        }
    }
}

pub fn remember_bounds(app: &AppHandle, view: &str, bounds: Bounds) {
    let engine = app.state::<Engine>();
    let mut data = engine.lock();
    if data.disk.bounds.get(view) == Some(&bounds) {
        return;
    }
    data.disk.bounds.insert(view.into(), bounds);
    if let Err(err) = engine.persist(&data) {
        eprintln!("{err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::calendar::{parse_icalendar, ParseOptions};
    use crate::dav::CalendarInfo;
    use crate::model::Pin;
    use std::fs;

    #[test]
    fn legacy_data_is_imported_once_and_only_current_range_reaches_the_calendar() {
        let root = tempfile::tempdir().unwrap();
        let old = root.path().join("old");
        let new = root.path().join("new").join("calendarbar.json");
        fs::create_dir_all(&old).unwrap();
        let text = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:today\nDTSTART:20261116T090000Z\nDTEND:20261116T100000Z\nSUMMARY:Встреча\nEND:VEVENT\nBEGIN:VEVENT\nUID:archive\nDTSTART:20240116T090000Z\nDTEND:20240116T100000Z\nSUMMARY:Архив\nEND:VEVENT\nEND:VCALENDAR";
        let login = "test@example.test";
        let href = "https://caldav.yandex.ru/calendars/test/events/";
        let meetings = parse_icalendar(
            text,
            ParseOptions {
                calendar_id: href,
                calendar_name: "Работа",
                account_login: login,
                fallback_zone: chrono_tz::UTC,
                display_zone: Some(chrono_tz::UTC),
                resource_url: Some(href),
                etag: None,
                range: None,
            },
        )
        .unwrap();
        let first = meetings
            .iter()
            .find(|meeting| meeting.title == "Встреча")
            .unwrap()
            .clone();
        let id = scoped_id(href, login);
        let range = Range::checked(first.start - 1, first.end + 1).unwrap();
        let old_json = json!({
            "primaryLogin": login,
            "globals": {"appearance": "dark", "autoStart": true},
            "accounts": [{
                "login": login, "active": true, "calendars": [{
                    "id": id, "sourceID": href, "name": "Работа", "accountLogin": login,
                    "listed": true, "notify": false, "visible": true, "color": "#1ACB64"
                }],
                "settings": {"firstReminderMinutes": 27},
                "cache": {id.clone(): {
                    "meetings": meetings.iter().map(|meeting| (&meeting.id, meeting)).collect::<BTreeMap<_,_>>(),
                    "coverage": [range], "resources": {}
                }},
                "pins": [{"id": "room", "login": login, "title": "Комната", "url": "https://meet.google.com/test"}],
                "reminders": {first.id.clone(): {"minutes":[17]}},
                "activity": [{"id": "change", "login": login, "kind": "changed", "meeting": first, "at": first.start, "unread": true}]
            }]
        });
        fs::write(old.join("calendarbar.json"), old_json.to_string()).unwrap();
        let engine = Engine::open(new.clone(), Some(old.clone())).unwrap();
        let mut data = engine.lock();
        assert_eq!(data.disk.globals.appearance, "dark");
        assert!(!data.disk.globals.auto_start);
        assert_eq!(data.disk.accounts[0].settings.first_reminder_minutes, 27);
        data.update_view("calendar", range);
        let state = data.snapshot("calendar");
        assert_eq!(state["meetings"].as_array().unwrap().len(), 1);
        assert_eq!(state["meetings"][0]["title"], "Встреча");
        assert_eq!(state["accounts"][0]["calendars"][0]["sourceID"], href);
        assert!(!state["accounts"][0]
            .as_object()
            .unwrap()
            .contains_key("password"));
        assert_eq!(state["activity"][0]["unread"], true);
        let profile = &mut data.disk.accounts[0];
        profile.merge_calendars(vec![CalendarInfo {
            id,
            source_id: href.into(),
            name: "Команда".into(),
            account_login: login.into(),
        }]);
        assert_eq!(profile.calendars[0].info.name, "Команда");
        assert!(!profile.calendars[0].notify);
        assert!(profile.clear_cache(now()) > 0);
        assert_eq!(profile.pins[0].title, "Комната");
        profile.pins.push(Pin {
            id: "saved".into(),
            login: login.into(),
            title: "Сохранено".into(),
            url: "https://example.test".into(),
        });
        engine.persist(&data).unwrap();
        drop(data);
        let loaded = Engine::open(new, Some(old.clone())).unwrap();
        assert_eq!(loaded.lock().disk.accounts[0].pins.len(), 2);
        assert_eq!(loaded.lock().disk.accounts[0].cache.len(), 0);
        assert_eq!(
            fs::read_to_string(old.join("calendarbar.json")).unwrap(),
            old_json.to_string()
        );
    }
}
