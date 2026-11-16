use crate::{
    calendar::{browser_url, telemost_desktop_url, Meeting},
    engine::{publish, Engine, Navigation},
    model::{
        combine_ranges, day_at, is_declined, local_time, now, Activity, Disk, Range, DAY, MINUTE,
    },
    operations,
    platform::{self, action_url},
};
use serde_json::json;
use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};
use tauri::{AppHandle, Manager};
use url::Url;

struct Notice {
    title: String,
    body: String,
    launch: String,
    actions: Vec<(&'static str, String)>,
}

fn meeting_notice(meeting: &Meeting, body: String, reminder: bool, at: i64) -> Notice {
    let id = Some(meeting.id.as_str());
    let mut actions = Vec::new();
    if reminder {
        if meeting.link.is_some() {
            actions.push(("Подключиться", action_url("join", id, None)));
        }
        actions.push(("Через 5 минут", action_url("snooze", id, None)));
        if meeting.start > at {
            actions.push(("В начале встречи", action_url("start", id, None)));
        }
        actions.push(("Больше не напоминать", action_url("mute", id, None)));
    }
    Notice {
        title: meeting.title.clone(),
        body,
        launch: action_url("meeting", id, None),
        actions,
    }
}

fn set_status(app: &AppHandle, status: String) {
    let engine = app.state::<Engine>();
    let mut data = engine.lock();
    if data.notification_status != status {
        data.notification_status = status;
        drop(data);
        publish(app);
    }
}

fn show(app: &AppHandle, notice: Notice, success: &'static str) {
    let handle = app.clone();
    // Send WinRT notifications from the application's UI thread.
    if let Err(error) = app.run_on_main_thread(move || {
        let actions = notice
            .actions
            .iter()
            .map(|(label, action)| (*label, action.as_str()))
            .collect::<Vec<_>>();
        let status = match platform::show_notification(
            &notice.title,
            &notice.body,
            Some(&notice.launch),
            &actions,
        ) {
            Ok(()) => success.into(),
            Err(platform::NotificationError::Disabled(message)) => message,
            Err(platform::NotificationError::Failed(message)) => {
                format!("Не удалось показать уведомление. {message}")
            }
        };
        set_status(&handle, status);
    }) {
        set_status(
            app,
            format!("Не удалось запустить отправку уведомления. {error}"),
        );
    }
}

pub fn test(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        show(
            &app,
            Notice {
                title: "CalendarBar".into(),
                body: "Уведомления работают.".into(),
                launch: action_url("calendar", None, None),
                actions: Vec::new(),
            },
            "Windows приняла тестовое уведомление. Если баннер не появился, проверьте центр уведомлений (Win + N).",
        );
    });
}

pub fn notify_change(app: &AppHandle, change: &Activity) {
    let notice = {
        let engine = app.state::<Engine>();
        let data = engine.lock();
        let Some(profile) = data
            .disk
            .account(&change.login)
            .filter(|profile| profile.active)
        else {
            return;
        };
        let settings = &profile.settings;
        let allowed = if change.kind == "new" {
            settings.notify_new
        } else {
            settings.notify_changes
        };
        if !allowed
            || (!change.important && !settings.notify_minor_changes)
            || is_declined(&change.meeting, &change.login)
        {
            return;
        }
        let label = match change.kind.as_str() {
            "new" => "Новая встреча",
            "cancelled" => "Встреча отменена",
            _ => "Встреча изменена",
        };
        let body = format!("{label} · {}", time_label(change.meeting.start));
        meeting_notice(&change.meeting, body, false, now())
    };
    show(app, notice, "Системные уведомления");
}

fn time_label(at: i64) -> String {
    local_time(at).format("%d.%m.%Y, %H:%M").to_string()
}

#[derive(Debug)]
struct Plan {
    login: String,
    key: String,
    at: i64,
    minutes: Option<i64>,
    meeting: Meeting,
}

fn plans(disk: &Disk, now: i64, grace: i64) -> Vec<Plan> {
    let window = Range {
        from: now - grace,
        to: now + 16 * DAY,
    };
    let mut plans = Vec::new();
    for profile in disk.active() {
        let enabled: BTreeSet<&str> = profile
            .calendars
            .iter()
            .filter(|calendar| calendar.notify)
            .map(|calendar| calendar.info.id.as_str())
            .collect();
        let snoozes: BTreeMap<&str, _> = profile
            .snoozes
            .iter()
            .map(|delay| (delay.meeting.id.as_str(), delay))
            .collect();
        let events: BTreeMap<&str, &Meeting> = profile
            .snoozes
            .iter()
            .map(|delay| &delay.meeting)
            .chain(profile.meetings().filter(|event| window.includes(event)))
            .map(|meeting| (meeting.id.as_str(), meeting))
            .collect();
        let defaults = profile.settings.offsets();
        for (id, meeting) in events {
            if !enabled.contains(meeting.calendar_id.as_str())
                || meeting.all_day
                || meeting.cancelled
                || meeting.end <= now
                || is_declined(meeting, &profile.login)
            {
                continue;
            }
            let preferences = profile
                .reminders
                .get(id)
                .or_else(|| profile.reminders.get(&meeting.series_id));
            if preferences.is_some_and(|entry| entry.muted) {
                continue;
            }
            let delay = snoozes.get(id).filter(|delay| {
                delay.at >= window.from
                    && delay.meeting.start == meeting.start
                    && delay.meeting.end == meeting.end
                    && delay.meeting.link == meeting.link
            });
            let unique: BTreeSet<_> = preferences
                .and_then(|reminder| reminder.minutes.as_ref())
                .unwrap_or(&defaults)
                .iter()
                .copied()
                .map(|value| value.clamp(1, 1440))
                .collect();
            let scheduled = unique
                .into_iter()
                .map(|minutes| (meeting.start - minutes * MINUTE, Some(minutes)))
                .filter(|(at, _)| delay.is_none_or(|delay| *at > delay.at))
                .chain(delay.map(|delay| (delay.at, None)));
            for (at, minutes) in scheduled {
                if at < window.from || at >= meeting.end {
                    continue;
                }
                let key =
                    json!([id, meeting.start, meeting.end, meeting.link, at, minutes]).to_string();
                if !profile.delivered.contains_key(&key) {
                    plans.push(Plan {
                        login: profile.login.clone(),
                        key,
                        at,
                        minutes,
                        meeting: meeting.clone(),
                    });
                }
            }
        }
    }
    plans.sort_unstable_by(|left, right| (left.at, &left.key).cmp(&(right.at, &right.key)));
    plans.truncate(60);
    plans
}

fn overview(disk: &Disk, at: i64) -> (Option<i64>, String) {
    let day = day_at(at, 0, 0, 0);
    let key = chrono::Utc
        .timestamp_millis_opt(day)
        .single()
        .map(|date| date.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
        .unwrap_or_else(|| day.to_string());
    let settings = disk.preferences();
    if !settings.daily_overview_enabled
        || !disk
            .account(&disk.primary_login)
            .is_some_and(|profile| profile.active)
    {
        return (None, key);
    }
    let candidate = day_at(
        at,
        0,
        settings.daily_overview_hour,
        settings.daily_overview_minute,
    );
    let when = if candidate < at - 2 * MINUTE || disk.overview_day == key {
        day_at(
            at,
            1,
            settings.daily_overview_hour,
            settings.daily_overview_minute,
        )
    } else {
        candidate
    };
    (Some(when), key)
}

fn overview_body(disk: &Disk, now: i64) -> String {
    let today = Range {
        from: day_at(now, 0, 0, 0),
        to: day_at(now, 1, 0, 0),
    };
    let working = disk.preferences().workday_range(now);
    let meetings: Vec<_> = disk
        .active()
        .flat_map(|profile| {
            let ids: BTreeSet<&str> = profile
                .calendars
                .iter()
                .filter(|cal| cal.notify)
                .map(|cal| cal.info.id.as_str())
                .collect();
            profile.meetings().filter(move |event| {
                !event.cancelled
                    && today.includes(event)
                    && ids.contains(event.calendar_id.as_str())
                    && !is_declined(event, &profile.login)
            })
        })
        .collect();
    let busy: Vec<_> = meetings
        .iter()
        .copied()
        .filter(|event| !event.all_day && !event.is_free && event.end > event.start)
        .collect();
    let ranges = combine_ranges(
        busy.iter()
            .filter_map(|event| {
                let from = event.start.max(working.from);
                let to = event.end.min(working.to);
                (from < to).then_some(Range { from, to })
            })
            .collect(),
    );
    let duration: i64 = ranges.iter().map(|range| range.to - range.from).sum();
    let conflicts: usize = busy
        .iter()
        .enumerate()
        .map(|(i, event)| {
            busy[i + 1..]
                .iter()
                .filter(|other| event.start < other.end && event.end > other.start)
                .count()
        })
        .sum();
    format!(
        "Встреч: {} · занято: {} мин. · пересечений: {conflicts}",
        meetings.len(),
        (duration + 30_000) / MINUTE
    )
}

use chrono::TimeZone;

fn pass(app: &AppHandle) -> Duration {
    let engine = app.state::<Engine>();
    let at = now();
    let mut notices = Vec::new();
    let wait = {
        let mut data = engine.lock();
        let grace = (at - data.last_reminder_check).clamp(0, 2 * MINUTE);
        data.last_reminder_check = at;
        let scheduled = plans(&data.disk, at, grace);
        let (overview_time, today_key) = overview(&data.disk, at);
        let mut next = at + MINUTE;
        for plan in scheduled {
            if plan.at > at {
                next = plan.at.min(next);
                break;
            }
            let Ok(profile) = data.disk.account_mut(&plan.login) else {
                continue;
            };
            profile.delivered.retain(|_, sent| at - *sent <= 16 * DAY);
            profile.delivered.insert(plan.key, at);
            profile
                .snoozes
                .retain(|snooze| snooze.at != plan.at || snooze.meeting.id != plan.meeting.id);
            let description = plan
                .minutes
                .map(|minutes| format!("До начала: {minutes} мин."))
                .unwrap_or_else(|| "Вы просили напомнить".into());
            notices.push(meeting_notice(
                &plan.meeting,
                format!("{description} · {}", time_label(plan.meeting.start)),
                true,
                at,
            ));
        }
        if let Some(when) = overview_time {
            if when <= at {
                data.disk.overview_day = today_key;
                notices.push(Notice {
                    title: "Ваш день в CalendarBar".into(),
                    body: overview_body(&data.disk, at),
                    launch: action_url("calendar", None, Some(day_at(at, 0, 0, 0))),
                    actions: Vec::new(),
                });
            } else {
                next = next.min(when);
            }
        }
        if !notices.is_empty() {
            if let Err(error) = engine.persist(&data) {
                eprintln!("{error}");
            }
        }
        Duration::from_millis((next - at).max(100) as u64)
    };
    if !notices.is_empty() {
        publish(app);
    }
    for notice in notices {
        show(app, notice, "Системные уведомления");
    }
    wait
}

pub fn remove(app: &AppHandle, ids: BTreeSet<String>) {
    if !ids.is_empty() {
        let _ = app.run_on_main_thread(move || {
            for id in ids {
                let _ = platform::remove_notification(&id);
            }
        });
    }
}

pub async fn run(app: AppHandle) {
    let state = app.state::<Engine>();
    loop {
        let wait = pass(&app);
        let _ = tokio::time::timeout(wait, state.reminder_wakeup.notified()).await;
    }
}

pub fn open_link(value: &str, join: bool) -> Result<(), String> {
    let url = Url::parse(value).map_err(|_| "Укажите корректную ссылку.")?;
    if !matches!(url.scheme(), "https" | "http")
        || url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("Укажите обычную ссылку HTTP или HTTPS.".into());
    }
    if join {
        if let Some(desktop) = telemost_desktop_url(value) {
            if platform::open_external(&desktop).is_ok() {
                return Ok(());
            }
        }
    }
    platform::open_external(&browser_url(url.as_str()))
}

pub fn handle_activation(app: &AppHandle, url: &Url) -> Result<(), String> {
    if url.scheme() != platform::ACTIVATION_SCHEME {
        return Err("Неизвестное действие.".into());
    }
    let id = url
        .query_pairs()
        .find(|(key, _)| key == "id")
        .map(|(_, value)| value.into_owned());
    let date = url
        .query_pairs()
        .find(|(key, _)| key == "date")
        .and_then(|(_, value)| value.parse::<i64>().ok())
        .filter(|at| chrono::Utc.timestamp_millis_opt(*at).single().is_some());
    let command = url.host_str().unwrap_or_default();
    if command == "calendar" {
        return crate::open_window(
            app,
            "calendar",
            Navigation {
                date,
                ..Navigation::default()
            },
        )
        .map(|_| ());
    }
    let id = id.ok_or("Встреча недоступна.")?;
    let meeting = app
        .state::<Engine>()
        .lock()
        .disk
        .event(&id)
        .cloned()
        .ok_or("Встреча недоступна.")?;
    let open_meeting = || {
        crate::open_window(
            app,
            "meeting",
            Navigation {
                meeting: Some(id.clone()),
                ..Navigation::default()
            },
        )
        .map(|_| ())
    };
    match command {
        "meeting" => open_meeting(),
        "join" => match &meeting.link {
            Some(link) if !meeting.cancelled && meeting.end > now() => open_link(link, true),
            _ => open_meeting(),
        },
        "snooze" | "start" => operations::mutate(
            app,
            "snooze",
            &json!({"id": id, "minutes": 5, "atStart": command=="start"}),
        )
        .map(|_| ())
        .or_else(|_| open_meeting()),
        "mute" => operations::mutate(
            app,
            "reminder",
            &json!({"id": id, "value": {"muted": true}}),
        )
        .map(|_| ()),
        _ => Err("Неизвестное действие.".into()),
    }
}

pub fn notification_settings() -> Result<(), String> {
    platform::open_external("ms-settings:notifications")
}

pub fn valid_copy(value: &str) -> Result<(), String> {
    let url = Url::parse(value).map_err(|_| "Укажите корректную ссылку.")?;
    if matches!(url.scheme(), "http" | "https")
        && url.username().is_empty()
        && url.password().is_none()
    {
        platform::copy_text(value)
    } else {
        Err("Укажите обычную ссылку HTTP или HTTPS.".into())
    }
}
