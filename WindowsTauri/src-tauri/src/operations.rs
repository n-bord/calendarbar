use crate::{
    calendar::{is_usable_meeting_url, telemost_desktop_url, Meeting},
    engine::{publish, spawn_refresh, Engine},
    model::{now, Pin, Preferences, Reminder, Snooze, MINUTE},
    platform,
};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use tauri::{AppHandle, Manager};

fn field<'a>(input: &'a Value, key: &str) -> &'a str {
    input[key].as_str().unwrap_or_default()
}
fn boolean(input: &Value, key: &str) -> bool {
    input[key] == true
}
fn label(text: &str, max: usize) -> String {
    text.trim().chars().take(max).collect()
}

fn color(value: &Value) -> Result<String, String> {
    let value = value.as_str().unwrap_or_default();
    if value.is_empty()
        || [
            "blue", "green", "orange", "red", "violet", "cyan", "lime", "yellow", "pink", "gray",
        ]
        .contains(&value)
        || (value.len() == 7
            && value.starts_with('#')
            && value[1..].bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        Ok(value.into())
    } else {
        Err("Выберите цвет из палитры.".into())
    }
}

fn bounded(value: &Value, low: i64, high: i64) -> Result<i64, String> {
    value
        .as_i64()
        .map(|value| value.clamp(low, high))
        .ok_or_else(|| "Укажите целое число.".into())
}

fn setting_i64(map: &Value, key: &str, into: &mut i64, min: i64, max: i64) -> Result<(), String> {
    if let Some(value) = map.get(key) {
        *into = bounded(value, min, max)?;
    }
    Ok(())
}

fn setting_u32(map: &Value, key: &str, into: &mut u32, min: i64, max: i64) -> Result<(), String> {
    if let Some(value) = map.get(key) {
        *into = bounded(value, min, max)? as u32;
    }
    Ok(())
}

#[cfg(test)]
mod workday_tests {
    use super::*;
    use crate::model::{day_at, Disk};
    use chrono::TimeZone;

    #[test]
    fn workday_minutes_round_trip_and_control_sync_boundaries() {
        let mut prefs: Preferences =
            serde_json::from_value(json!({"workdayStartHour": 9, "workdayEndHour": 18})).unwrap();
        assert_eq!(prefs.workday_minutes(), 540..1080);
        update_preferences(
            &mut prefs,
            &json!({"workdayStartMinute": 30, "workdayEndMinute": 15}),
        )
        .unwrap();
        let prefs: Preferences =
            serde_json::from_value(serde_json::to_value(&prefs).unwrap()).unwrap();
        assert_eq!(prefs.workday_minutes(), 570..1095);

        let monday = chrono::Local
            .with_ymd_and_hms(2026, 11, 16, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let disk = Disk {
            unlinked_settings: prefs,
            ..Default::default()
        };
        let workday = disk.preferences().workday_range(monday);
        assert_eq!(workday.from, day_at(monday, 0, 9, 30));
        assert_eq!(workday.to, day_at(monday, 0, 18, 15));
        assert_eq!(disk.refresh_interval(workday.from - 1), 30 * MINUTE);
        assert_eq!(disk.refresh_interval(workday.from), 5 * MINUTE);
        assert_eq!(disk.refresh_interval(workday.to - 1), 5 * MINUTE);
        assert_eq!(disk.refresh_interval(workday.to), 30 * MINUTE);
    }

    #[test]
    fn workday_edits_preserve_valid_ranges_and_midnight() {
        let mut prefs = Preferences::default();
        update_preferences(
            &mut prefs,
            &json!({"workdayStartHour": 18, "workdayStartMinute": 55}),
        )
        .unwrap();
        assert_eq!(prefs.workday_minutes(), 1135..1195);
        update_preferences(&mut prefs, &json!({"workdayEndMinute": 45})).unwrap();
        assert_eq!(prefs.workday_minutes(), 1135..1185);
        update_preferences(&mut prefs, &json!({"workdayEndHour": 24})).unwrap();
        assert_eq!(prefs.workday_end_minute, 0);
        assert_eq!(prefs.workday_minutes().end, 1440);
        update_preferences(
            &mut prefs,
            &json!({"workdayEndHour": 0, "workdayEndMinute": 25}),
        )
        .unwrap();
        assert_eq!(prefs.workday_minutes(), 0..25);
    }
}

fn update_preferences(prefs: &mut Preferences, values: &Value) -> Result<(), String> {
    for (key, slot) in [
        ("notifyNew", &mut prefs.notify_new),
        ("notifyChanges", &mut prefs.notify_changes),
        ("notifyMinorChanges", &mut prefs.notify_minor_changes),
        ("firstReminderEnabled", &mut prefs.first_reminder_enabled),
        ("secondReminderEnabled", &mut prefs.second_reminder_enabled),
        ("dailyOverviewEnabled", &mut prefs.daily_overview_enabled),
    ] {
        if let Some(value) = values[key].as_bool() {
            *slot = value;
        }
    }
    setting_i64(
        values,
        "firstReminderMinutes",
        &mut prefs.first_reminder_minutes,
        1,
        1440,
    )?;
    setting_i64(
        values,
        "secondReminderMinutes",
        &mut prefs.second_reminder_minutes,
        1,
        1440,
    )?;
    setting_u32(
        values,
        "workdayStartHour",
        &mut prefs.workday_start_hour,
        0,
        23,
    )?;
    setting_u32(
        values,
        "workdayStartMinute",
        &mut prefs.workday_start_minute,
        0,
        59,
    )?;
    setting_u32(values, "workdayEndHour", &mut prefs.workday_end_hour, 0, 24)?;
    setting_u32(
        values,
        "workdayEndMinute",
        &mut prefs.workday_end_minute,
        0,
        59,
    )?;
    setting_u32(
        values,
        "dailyOverviewHour",
        &mut prefs.daily_overview_hour,
        0,
        23,
    )?;
    setting_u32(
        values,
        "dailyOverviewMinute",
        &mut prefs.daily_overview_minute,
        0,
        59,
    )?;
    let mut start = prefs.workday_start_hour.min(23) * 60 + prefs.workday_start_minute.min(59);
    let mut end =
        (prefs.workday_end_hour.min(24) * 60 + prefs.workday_end_minute.min(59)).clamp(1, 1440);
    if start >= end {
        if values.get("workdayStartHour").is_some() || values.get("workdayStartMinute").is_some() {
            end = (start + 60).min(1440);
        } else {
            start = end.saturating_sub(60);
        }
    }
    prefs.workday_start_hour = start / 60;
    prefs.workday_start_minute = start % 60;
    prefs.workday_end_hour = end / 60;
    prefs.workday_end_minute = end % 60;
    if let Some(value) = values["menuCountdownWindow"]
        .as_i64()
        .filter(|value| [0, 15, 30, 60, 180].contains(value))
    {
        prefs.menu_countdown_window = value;
    }
    if let Some(value) = values["menuMeetingsMode"].as_str().filter(|value| {
        [
            "currentAndUpcoming",
            "allToday",
            "upcomingOnly",
            "currentOnly",
        ]
        .contains(value)
    }) {
        prefs.menu_meetings_mode = value.into();
    }
    Ok(())
}

fn event(data: &crate::engine::Runtime, id: &str) -> Result<Meeting, String> {
    data.disk
        .event(id)
        .cloned()
        .ok_or_else(|| "Встреча недоступна.".into())
}

pub fn mutate(app: &AppHandle, action: &str, input: &Value) -> Result<Value, String> {
    let engine = app.state::<Engine>();
    let mut data = engine.lock();
    let login = field(input, "login");
    let id = field(input, "id");
    let mut refresh = None;
    let mut released = 0;
    let mut close_toasts = BTreeSet::new();
    let mut new_theme = None;
    match action {
        "settings" => {
            let values = &input["values"];
            let selected = if login.is_empty() {
                data.disk.primary_login.clone()
            } else {
                login.into()
            };
            let mut settings = if selected.is_empty() {
                data.disk.unlinked_settings.clone()
            } else {
                data.disk
                    .account(&selected)
                    .ok_or("Аккаунт не найден.")?
                    .settings
                    .clone()
            };
            update_preferences(&mut settings, values)?;
            if let Some(enabled) = values["autoStart"].as_bool() {
                platform::set_auto_start(enabled)?;
                data.disk.globals.auto_start = enabled;
            }
            if selected.is_empty() {
                data.disk.unlinked_settings = settings;
            } else {
                data.disk.account_mut(&selected)?.settings = settings;
            }
            let globals = &mut data.disk.globals;
            if let Some(theme) = values["appearance"]
                .as_str()
                .or_else(|| values["theme"].as_str())
                .filter(|theme| ["system", "light", "dark"].contains(theme))
            {
                globals.appearance = theme.into();
                new_theme = Some(theme);
            }
            if let Some(value) = values["workdayOnly"].as_bool() {
                globals.workday_only = value;
            }
            if let Some(view) = values["calendarView"]
                .as_str()
                .filter(|view| ["day", "week", "month", "agenda"].contains(view))
            {
                globals.calendar_view = view.into();
            }
            if let Some(value) = values["workdayRefreshMinutes"]
                .as_i64()
                .filter(|value| [1, 3, 5, 10, 15].contains(value))
            {
                globals.workday_refresh_minutes = value;
            }
            if let Some(value) = values["outsideRefreshMinutes"]
                .as_i64()
                .filter(|value| [0, 15, 30, 60, 120].contains(value))
            {
                globals.outside_refresh_minutes = value;
            }
        }
        "account" => {
            let account = data.disk.account_mut(login)?;
            if let Some(active) = input["active"].as_bool() {
                account.active = active;
                if active {
                    refresh = Some(login.to_owned());
                } else {
                    close_toasts.extend(account.meetings().map(|meeting| meeting.id.clone()));
                }
            }
            if let Some(visible) = input["visible"].as_bool() {
                account.visible = visible;
            }
            if let Some(value) = input["label"].as_str() {
                account.label = label(value, 64);
            }
            if boolean(input, "primary") {
                data.disk.primary_login = login.into();
            }
            data.disk.select_primary();
        }
        "disconnect" => {
            let before = data
                .disk
                .accounts
                .iter()
                .position(|account| account.login == login)
                .ok_or("Аккаунт не найден.")?;
            let account = data.disk.accounts.remove(before);
            close_toasts.extend(account.meetings().map(|event| event.id.clone()));
            if data.disk.primary_login == login {
                data.disk.select_primary();
            }
        }
        "calendar" => {
            let account = data
                .disk
                .accounts
                .iter_mut()
                .find(|account| account.calendars.iter().any(|item| item.info.id == id))
                .ok_or("Календарь не найден.")?;
            let Some(calendar) = account.calendars.iter_mut().find(|item| item.info.id == id)
            else {
                return Err("Календарь не найден.".into());
            };
            let new_color = input.get("color").map(color).transpose()?;
            if let Some(listed) = input["listed"].as_bool() {
                if listed && !calendar.listed && account.active {
                    refresh = Some(account.login.clone());
                }
                calendar.listed = listed;
            }
            if let Some(visible) = input["visible"].as_bool() {
                calendar.visible = visible;
            }
            if let Some(notify) = input["notify"].as_bool() {
                if notify && !calendar.notify {
                    account.baseline_calendars.insert(id.into());
                    if account.active {
                        refresh = Some(account.login.clone());
                    }
                }
                calendar.notify = notify;
            }
            if let Some(color) = new_color {
                calendar.color = color;
            }
        }
        "pin" => {
            let pins = if login.is_empty() {
                &mut data.disk.local_pins
            } else {
                &mut data.disk.account_mut(login)?.pins
            };
            let position = pins.iter().position(|pin| pin.id == id || pin.url == id);
            if boolean(input, "remove") {
                if let Some(index) = position {
                    pins.remove(index);
                }
            } else if let (Some(index), Some(offset)) = (position, input["offset"].as_i64()) {
                let destination =
                    (index as i64 + offset.signum()).clamp(0, pins.len() as i64 - 1) as usize;
                let pin = pins.remove(index);
                pins.insert(destination, pin);
            } else {
                let value = field(input, "url");
                if !is_usable_meeting_url(value) {
                    return Err("Укажите ссылку на конференцию.".into());
                }
                let url = url::Url::parse(value).map_err(|_| "Укажите ссылку на конференцию.")?;
                let identity =
                    telemost_desktop_url(url.as_str()).unwrap_or_else(|| url.to_string());
                if pins.iter().enumerate().any(|(i, pin)| {
                    Some(i) != position
                        && telemost_desktop_url(&pin.url).unwrap_or_else(|| pin.url.clone())
                            == identity
                }) {
                    return Err("Эта ссылка уже закреплена.".into());
                }
                let name = label(field(input, "title"), 256);
                let pin = Pin {
                    id: position
                        .map(|index| pins[index].id.clone())
                        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
                    title: if name.is_empty() {
                        url.host_str().unwrap_or_default().into()
                    } else {
                        name
                    },
                    url: url.into(),
                    login: login.into(),
                };
                if let Some(index) = position {
                    pins[index] = pin;
                } else {
                    pins.push(pin);
                }
            }
        }
        "hideLast" | "reminder" | "color" | "snooze" => {
            let meeting = event(&data, id)?;
            let account = data.disk.account_mut(
                meeting
                    .account_login
                    .as_deref()
                    .ok_or("Аккаунт не найден.")?,
            )?;
            let series = field(input, "scope") == "series";
            let key = if series {
                &meeting.series_id
            } else {
                &meeting.id
            };
            match action {
                "hideLast" => {
                    account.hidden_last = if boolean(input, "hidden") {
                        id.into()
                    } else {
                        String::new()
                    }
                }
                "color" => {
                    let color = color(&input["color"])?;
                    if color.is_empty() {
                        account.colors.remove(key);
                    } else {
                        account.colors.insert(key.clone(), color);
                    }
                }
                "reminder" => {
                    let value = &input["value"];
                    if value.is_null() {
                        account.reminders.remove(key);
                    } else {
                        let muted = boolean(value, "muted");
                        let minutes = if muted {
                            None
                        } else {
                            let offsets = value["minutes"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .map(|item| bounded(item, 1, 1440))
                                .collect::<Result<BTreeSet<_>, _>>()?;
                            Some(offsets.into_iter().rev().collect())
                        };
                        account
                            .reminders
                            .insert(key.clone(), Reminder { muted, minutes });
                    }
                    if series {
                        account.reminders.retain(|id, _| {
                            id.rsplit_once('|')
                                .is_none_or(|(series, _)| series != meeting.series_id)
                        });
                    }
                    account.snoozes.retain(|item| {
                        item.meeting.id != meeting.id
                            && (!series || item.meeting.series_id != meeting.series_id)
                    });
                    close_toasts.insert(meeting.id);
                }
                "snooze" => {
                    if boolean(input, "cancel") {
                        account.snoozes.retain(|item| item.meeting.id != meeting.id);
                    } else {
                        let current = now();
                        let at = if boolean(input, "atStart") {
                            meeting.start
                        } else {
                            current
                                + input
                                    .get("minutes")
                                    .map(|value| bounded(value, 1, 1440))
                                    .transpose()?
                                    .unwrap_or(5)
                                    * MINUTE
                        };
                        if at <= current
                            || at >= meeting.end
                            || meeting.cancelled
                            || meeting.all_day
                        {
                            return Err("Выберите время до окончания встречи.".into());
                        }
                        if account
                            .reminders
                            .get(id)
                            .or_else(|| account.reminders.get(&meeting.series_id))
                            .is_some_and(|setting| setting.muted)
                        {
                            account.reminders.insert(
                                id.into(),
                                Reminder {
                                    muted: false,
                                    minutes: Some(Vec::new()),
                                },
                            );
                        }
                        account.snoozes.retain(|item| item.meeting.id != meeting.id);
                        account.snoozes.push(Snooze { meeting, at });
                    }
                    close_toasts.insert(id.into());
                }
                _ => unreachable!(),
            }
        }
        "markActivity" | "clearActivity" => {
            for profile in data
                .disk
                .accounts
                .iter_mut()
                .filter(|profile| profile.active)
            {
                if action == "clearActivity" {
                    profile.activity.clear();
                } else {
                    for entry in &mut profile.activity {
                        if id.is_empty() || id == entry.id {
                            entry.unread = false;
                        }
                    }
                }
            }
        }
        "clearCalendarCache" => {
            if data.busy {
                return Err("Дождитесь окончания загрузки календаря и попробуйте снова.".into());
            }
            if !login.is_empty() && data.disk.account(login).is_none() {
                return Err("Аккаунт не найден.".into());
            }
            let mut cleared = BTreeSet::new();
            let mut original = Vec::new();
            let at = now();
            for (index, profile) in data.disk.accounts.iter_mut().enumerate() {
                if (!login.is_empty() && profile.login != login) || profile.cache_bytes() == 0 {
                    continue;
                }
                close_toasts.extend(profile.meetings().map(|event| event.id.clone()));
                let stripped = crate::model::Profile {
                    cache: std::mem::take(&mut profile.cache),
                    background: std::mem::take(&mut profile.background),
                    initialized: profile.initialized,
                    seen_series: std::mem::take(&mut profile.seen_series),
                    baseline_calendars: std::mem::take(&mut profile.baseline_calendars),
                    last_attempt: profile.last_attempt,
                    last_sync: profile.last_sync,
                    error: std::mem::take(&mut profile.error),
                    ..Default::default()
                };
                released += stripped.cache_bytes();
                profile.initialized = false;
                profile.last_attempt = at;
                profile.last_sync = 0;
                original.push((index, stripped));
                cleared.insert(profile.login.clone());
            }
            if let Err(problem) = engine.persist(&data) {
                for (index, backup) in original {
                    let profile = &mut data.disk.accounts[index];
                    profile.cache = backup.cache;
                    profile.background = backup.background;
                    profile.initialized = backup.initialized;
                    profile.seen_series = backup.seen_series;
                    profile.baseline_calendars = backup.baseline_calendars;
                    profile.last_attempt = backup.last_attempt;
                    profile.last_sync = backup.last_sync;
                    profile.error = backup.error;
                }
                return Err(problem);
            }
            data.reset_cache_focus(&cleared);
            data.sync_message.clear();
        }
        _ => return Err("Неизвестное действие.".into()),
    }
    if action != "clearCalendarCache" {
        engine.persist(&data)?;
    }
    drop(data);
    crate::notifications::remove(app, close_toasts);
    if let Some(theme) = new_theme {
        crate::apply_theme(app, theme);
    }
    publish(app);
    crate::update_tray(app);
    engine.reminder_wakeup.notify_one();
    if refresh.is_some() {
        spawn_refresh(app, refresh);
    }
    Ok(if action == "clearCalendarCache" {
        json!({ "releasedBytes": released })
    } else {
        json!({})
    })
}
