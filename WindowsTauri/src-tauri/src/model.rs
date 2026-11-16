use crate::calendar::{invitation_status, overlaps, Meeting};
use crate::dav::{
    merge_calendar_meetings, prune_calendar_resources, CalendarBatch, CalendarInfo, Resources,
};
use chrono::{Datelike, Days, Local, TimeZone};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::{self, Write},
    path::Path,
};

pub const DAY: i64 = 86_400_000;
pub const MINUTE: i64 = 60_000;

pub fn now() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

pub fn local_time(time: i64) -> chrono::DateTime<Local> {
    Local
        .timestamp_millis_opt(time)
        .single()
        .unwrap_or_else(Local::now)
}

pub fn day_at(time: i64, offset: i64, hour: u32, minute: u32) -> i64 {
    let shift = offset + i64::from(hour / 24);
    if hour % 24 == 0 && minute == 0 {
        let zone = display_zone();
        if let Some(at) = crate::calendar::add_calendar_days(time, shift, zone)
            .and_then(|at| crate::calendar::day_start(at, zone))
        {
            return at;
        }
    }
    let day = local_time(time).date_naive();
    let day = if shift < 0 {
        day.checked_sub_days(Days::new(shift.unsigned_abs()))
    } else {
        day.checked_add_days(Days::new(shift as u64))
    };
    day.and_then(|day| day.and_hms_opt(hour % 24, minute, 0))
        .and_then(|wall| {
            Local
                .from_local_datetime(&wall)
                .earliest()
                .map(|date| date.timestamp_millis())
                .or_else(|| {
                    let yesterday = wall.checked_sub_days(Days::new(1))?;
                    Local
                        .from_local_datetime(&yesterday)
                        .earliest()
                        .map(|date| date.timestamp_millis() + DAY)
                })
        })
        .unwrap_or_else(|| time.saturating_add(offset * DAY))
}

pub fn background_range(at: i64) -> Range {
    Range {
        from: day_at(at, -1, 0, 0),
        to: day_at(at, 15, 0, 0),
    }
}

pub fn display_zone() -> chrono_tz::Tz {
    crate::calendar::local_zone()
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Range {
    pub from: i64,
    pub to: i64,
}

impl Range {
    pub fn checked(from: i64, to: i64) -> Result<Self, String> {
        if from >= to
            || to.saturating_sub(from) > 3 * 366 * DAY + 120 * MINUTE
            || chrono::Utc.timestamp_millis_opt(from).single().is_none()
            || chrono::Utc.timestamp_millis_opt(to).single().is_none()
        {
            return Err("Выберите период не длиннее трёх лет.".into());
        }
        Ok(Self { from, to })
    }

    pub fn covers(self, range: Self) -> bool {
        self.from <= range.from && self.to >= range.to
    }

    pub fn includes(self, meeting: &Meeting) -> bool {
        overlaps(meeting, self.from, self.to)
    }
}

pub fn combine_ranges(mut ranges: Vec<Range>) -> Vec<Range> {
    ranges.sort_unstable_by_key(|item| item.from);
    let mut combined: Vec<Range> = Vec::new();
    for range in ranges {
        if let Some(last) = combined.last_mut().filter(|last| last.to >= range.from) {
            last.to = last.to.max(range.to);
        } else {
            combined.push(range);
        }
    }
    combined
}

fn intersect_ranges(left: Vec<Range>, right: &[Range]) -> Vec<Range> {
    let mut combined = Vec::new();
    let (mut i, mut j) = (0, 0);
    while i < left.len() && j < right.len() {
        let from = left[i].from.max(right[j].from);
        let to = left[i].to.min(right[j].to);
        if from < to {
            combined.push(Range { from, to });
        }
        if left[i].to < right[j].to {
            i += 1;
        } else {
            j += 1;
        }
    }
    combined
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Preferences {
    pub zone: String,
    pub notify_new: bool,
    pub notify_changes: bool,
    pub notify_minor_changes: bool,
    pub first_reminder_enabled: bool,
    pub first_reminder_minutes: i64,
    pub second_reminder_enabled: bool,
    pub second_reminder_minutes: i64,
    pub workday_start_hour: u32,
    pub workday_start_minute: u32,
    pub workday_end_hour: u32,
    pub workday_end_minute: u32,
    pub daily_overview_enabled: bool,
    pub daily_overview_hour: u32,
    pub daily_overview_minute: u32,
    pub menu_countdown_window: i64,
    pub menu_meetings_mode: String,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            zone: "Europe/Moscow".into(),
            notify_new: true,
            notify_changes: true,
            notify_minor_changes: false,
            first_reminder_enabled: true,
            first_reminder_minutes: 15,
            second_reminder_enabled: true,
            second_reminder_minutes: 5,
            workday_start_hour: 9,
            workday_start_minute: 0,
            workday_end_hour: 18,
            workday_end_minute: 0,
            daily_overview_enabled: false,
            daily_overview_hour: 9,
            daily_overview_minute: 0,
            menu_countdown_window: 60,
            menu_meetings_mode: "currentAndUpcoming".into(),
        }
    }
}

impl Preferences {
    pub fn workday_minutes(&self) -> std::ops::Range<u32> {
        let start = self.workday_start_hour.min(23) * 60 + self.workday_start_minute.min(59);
        let end = (self.workday_end_hour.min(24) * 60 + self.workday_end_minute.min(59))
            .clamp(start + 1, 1440);
        start..end
    }

    pub fn workday_range(&self, at: i64) -> Range {
        let minutes = self.workday_minutes();
        Range {
            from: day_at(at, 0, minutes.start / 60, minutes.start % 60),
            to: day_at(at, 0, minutes.end / 60, minutes.end % 60),
        }
    }

    pub fn tz(&self) -> chrono_tz::Tz {
        self.zone.parse().unwrap_or(chrono_tz::Europe::Moscow)
    }

    pub fn offsets(&self) -> Vec<i64> {
        [
            (self.first_reminder_enabled, self.first_reminder_minutes),
            (self.second_reminder_enabled, self.second_reminder_minutes),
        ]
        .into_iter()
        .filter_map(|(enabled, minutes)| enabled.then_some(minutes.clamp(1, 1440)))
        .collect()
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Globals {
    pub appearance: String,
    pub auto_start: bool,
    pub workday_refresh_minutes: i64,
    pub outside_refresh_minutes: i64,
    pub workday_only: bool,
    pub calendar_view: String,
}

impl Default for Globals {
    fn default() -> Self {
        Self {
            appearance: "system".into(),
            auto_start: false,
            workday_refresh_minutes: 5,
            outside_refresh_minutes: 30,
            workday_only: true,
            calendar_view: "week".into(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Calendar {
    #[serde(flatten)]
    pub info: CalendarInfo,
    #[serde(default = "yes")]
    pub listed: bool,
    #[serde(default = "yes")]
    pub visible: bool,
    #[serde(default = "yes")]
    pub notify: bool,
    #[serde(default, deserialize_with = "nullable_string")]
    pub color: String,
}

fn yes() -> bool {
    true
}

fn nullable_string<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<String, D::Error> {
    Option::<String>::deserialize(deserializer).map(Option::unwrap_or_default)
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Cache {
    pub meetings: BTreeMap<String, Meeting>,
    pub resources: Resources,
    pub coverage: Vec<Range>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Pin {
    pub id: String,
    pub title: String,
    pub url: String,
    #[serde(default)]
    pub login: String,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Reminder {
    pub muted: bool,
    pub minutes: Option<Vec<i64>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Snooze {
    pub meeting: Meeting,
    pub at: i64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Activity {
    pub id: String,
    pub login: String,
    pub kind: String,
    pub meeting: Meeting,
    pub previous: Option<Meeting>,
    #[serde(default = "yes")]
    pub important: bool,
    pub at: i64,
    pub unread: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct Bounds {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Profile {
    pub login: String,
    pub label: String,
    pub active: bool,
    pub visible: bool,
    pub settings: Preferences,
    pub calendars: Vec<Calendar>,
    pub cache: BTreeMap<String, Cache>,
    pub background: Vec<Meeting>,
    pub initialized: bool,
    pub seen_series: BTreeMap<String, i64>,
    pub baseline_calendars: BTreeSet<String>,
    pub reminders: BTreeMap<String, Reminder>,
    pub colors: BTreeMap<String, String>,
    pub pins: Vec<Pin>,
    pub snoozes: Vec<Snooze>,
    pub delivered: BTreeMap<String, i64>,
    pub activity: Vec<Activity>,
    pub hidden_last: String,
    pub last_attempt: i64,
    pub last_sync: i64,
    pub error: String,
    // The existing Electron value stays encrypted during import.
    pub password: Option<String>,
}

impl Default for Profile {
    fn default() -> Self {
        Self {
            login: String::new(),
            label: String::new(),
            active: true,
            visible: true,
            settings: Preferences::default(),
            calendars: Vec::new(),
            cache: BTreeMap::new(),
            background: Vec::new(),
            initialized: false,
            seen_series: BTreeMap::new(),
            baseline_calendars: BTreeSet::new(),
            reminders: BTreeMap::new(),
            colors: BTreeMap::new(),
            pins: Vec::new(),
            snoozes: Vec::new(),
            delivered: BTreeMap::new(),
            activity: Vec::new(),
            hidden_last: String::new(),
            last_attempt: 0,
            last_sync: 0,
            error: String::new(),
            password: None,
        }
    }
}

impl Profile {
    pub fn name(&self) -> &str {
        if self.label.is_empty() {
            &self.login
        } else {
            &self.label
        }
    }

    pub fn meetings(&self) -> impl Iterator<Item = &Meeting> {
        self.cache
            .values()
            .flat_map(|entry| entry.meetings.values())
    }

    pub fn merge_calendars(&mut self, calendars: Vec<CalendarInfo>) {
        self.calendars = calendars
            .into_iter()
            .map(|info| {
                let existing = self.calendars.iter().find(|item| item.info.id == info.id);
                match existing {
                    Some(old) => Calendar {
                        info,
                        ..old.clone()
                    },
                    None => Calendar {
                        info,
                        listed: true,
                        visible: true,
                        notify: true,
                        color: String::new(),
                    },
                }
            })
            .collect();
        let ids: BTreeSet<&str> = self
            .calendars
            .iter()
            .map(|item| item.info.id.as_str())
            .collect();
        self.cache.retain(|id, _| ids.contains(id.as_str()));
    }

    pub fn reconcile(&mut self, id: &str, range: Range, mut batch: CalendarBatch) {
        let cache = self.cache.entry(id.into()).or_default();
        let mut previous = Vec::new();
        cache.meetings.retain(|_, event| {
            if !range.includes(event) {
                return true;
            }
            previous.push(event.clone());
            false
        });
        for meeting in merge_calendar_meetings(previous, &mut batch) {
            cache.meetings.insert(meeting.id.clone(), meeting);
        }
        cache.resources.append(&mut batch.resources);
        cache.resources = prune_calendar_resources(std::mem::take(&mut cache.resources));
        if batch.complete {
            cache.coverage.push(range);
            cache.coverage = combine_ranges(std::mem::take(&mut cache.coverage));
        } else {
            cache.coverage = cache
                .coverage
                .iter()
                .flat_map(|entry| {
                    if entry.to <= range.from || entry.from >= range.to {
                        return vec![*entry];
                    }
                    let mut result = Vec::new();
                    if entry.from < range.from {
                        result.push(Range {
                            from: entry.from,
                            to: range.from,
                        });
                    }
                    if entry.to > range.to {
                        result.push(Range {
                            from: range.to,
                            to: entry.to,
                        });
                    }
                    result
                })
                .collect();
        }
    }

    pub fn cache_bytes(&self) -> usize {
        fn bytes<T: Serialize>(value: &T) -> usize {
            struct Count(usize);
            impl Write for Count {
                fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                    self.0 += bytes.len();
                    Ok(bytes.len())
                }
                fn flush(&mut self) -> io::Result<()> {
                    Ok(())
                }
            }
            let mut count = Count(0);
            if serde_json::to_writer(&mut count, value).is_ok() {
                count.0.saturating_sub(2)
            } else {
                0
            }
        }
        bytes(&self.cache)
            + bytes(&self.background)
            + bytes(&self.seen_series)
            + bytes(&self.baseline_calendars)
    }

    pub fn clear_cache(&mut self, at: i64) -> usize {
        let bytes = self.cache_bytes();
        self.cache.clear();
        self.background.clear();
        self.initialized = false;
        self.seen_series.clear();
        self.baseline_calendars.clear();
        self.last_attempt = at;
        self.last_sync = 0;
        self.error.clear();
        bytes
    }

    pub fn activity(
        &mut self,
        range: Range,
        successful: &BTreeSet<String>,
        at: i64,
        had_errors: bool,
    ) -> Vec<Activity> {
        let latest: Vec<Meeting> =
            self.meetings()
                .filter(|event| {
                    range.includes(event)
                        && self.calendars.iter().any(|calendar| {
                            calendar.notify && calendar.info.id == event.calendar_id
                        })
                })
                .cloned()
                .collect();
        if !self.initialized {
            self.baseline_calendars = self
                .calendars
                .iter()
                .filter(|cal| cal.notify && !successful.contains(&cal.info.id))
                .map(|cal| cal.info.id.clone())
                .collect();
        }
        let prior: BTreeMap<&str, &Meeting> = self
            .background
            .iter()
            .map(|event| (event.id.as_str(), event))
            .collect();
        let mut changes = Vec::new();
        if self.initialized {
            for event in &latest {
                if event.end <= at
                    || !successful.contains(&event.calendar_id)
                    || self.baseline_calendars.contains(&event.calendar_id)
                {
                    continue;
                }
                let previous = prior.get(event.id.as_str()).copied();
                let transition = if let Some(old) = previous {
                    let important = old.start != event.start
                        || old.end != event.end
                        || old.all_day != event.all_day
                        || old.all_day_dates != event.all_day_dates
                        || old.title != event.title
                        || old.location != event.location
                        || old.link != event.link
                        || old.cancelled != event.cancelled;
                    let attendees = |event: &Meeting| {
                        let mut list: Vec<Value> = event
                            .attendees
                            .iter()
                            .map(|attendee| json!(attendee))
                            .collect();
                        list.sort_by_key(|item| {
                            item["email"].as_str().unwrap_or_default().to_owned()
                        });
                        list
                    };
                    let minor = old.details != event.details
                        || old.organizer != event.organizer
                        || old.is_free != event.is_free
                        || attendees(old) != attendees(event);
                    (important || minor).then_some((
                        if event.cancelled && !old.cancelled {
                            "cancelled"
                        } else {
                            "changed"
                        },
                        important,
                    ))
                } else {
                    (!event.cancelled && !self.seen_series.contains_key(&event.series_id))
                        .then_some(("new", true))
                };
                if let Some((kind, important)) = transition {
                    changes.push(Activity {
                        id: uuid::Uuid::new_v4().to_string(),
                        kind: kind.into(),
                        login: self.login.clone(),
                        meeting: event.clone(),
                        previous: previous.cloned(),
                        important,
                        at,
                        unread: true,
                    });
                }
            }
        }
        changes.reverse();
        self.activity.splice(0..0, changes.clone());
        self.activity.truncate(200);
        self.initialized |= !successful.is_empty();
        if !successful.is_empty() || !had_errors {
            self.last_sync = at;
        }
        self.baseline_calendars
            .retain(|id| !successful.contains(id));
        self.seen_series.retain(|_, old| at - *old < 100 * DAY);
        let by_id = latest
            .iter()
            .map(|event| (event.id.as_str(), event))
            .collect::<BTreeMap<_, _>>();
        for event in &latest {
            self.seen_series.insert(event.series_id.clone(), at);
        }
        self.snoozes.retain_mut(|item| {
            if item.at < at || item.at >= item.meeting.end {
                return false;
            }
            if let Some(event) = by_id.get(item.meeting.id.as_str()).copied() {
                if event.cancelled
                    || event.start != item.meeting.start
                    || event.end != item.meeting.end
                    || event.link != item.meeting.link
                {
                    return false;
                }
                item.meeting = event.clone();
                return true;
            }
            !successful.contains(&item.meeting.calendar_id) || !range.includes(&item.meeting)
        });
        self.background = latest;
        changes
    }
}

#[derive(Default, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Disk {
    pub globals: Globals,
    pub unlinked_settings: Preferences,
    pub primary_login: String,
    pub accounts: Vec<Profile>,
    pub local_pins: Vec<Pin>,
    pub overview_day: String,
    pub bounds: BTreeMap<String, Bounds>,
}

impl Disk {
    pub fn read(file: &Path) -> Result<Option<Self>, String> {
        match fs::File::open(file) {
            Ok(file) => serde_json::from_reader(io::BufReader::new(file))
                .map(Some)
                .map_err(|err| format!("Не удалось прочитать настройки CalendarBar: {err}")),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(format!("Не удалось открыть настройки CalendarBar: {err}")),
        }
    }

    pub fn save(&self, file: &Path) -> Result<(), String> {
        let directory = file.parent().ok_or("Папка данных недоступна.")?;
        fs::create_dir_all(directory).map_err(|err| err.to_string())?;
        let mut temp = tempfile::NamedTempFile::new_in(directory).map_err(|err| err.to_string())?;
        {
            let mut writer = io::BufWriter::new(&mut temp);
            serde_json::to_writer(&mut writer, self).map_err(|err| err.to_string())?;
            writer.flush().map_err(|err| err.to_string())?;
        }
        temp.as_file().sync_all().map_err(|err| err.to_string())?;
        temp.persist(file).map_err(|err| err.to_string())?;
        Ok(())
    }

    pub fn active(&self) -> impl Iterator<Item = &Profile> {
        self.accounts.iter().filter(|account| account.active)
    }
    pub fn account(&self, login: &str) -> Option<&Profile> {
        self.accounts.iter().find(|item| item.login == login)
    }
    pub fn account_mut(&mut self, login: &str) -> Result<&mut Profile, String> {
        self.accounts
            .iter_mut()
            .find(|item| item.login == login)
            .ok_or_else(|| "Аккаунт не найден.".into())
    }

    pub fn preferences(&self) -> &Preferences {
        self.account(&self.primary_login)
            .map_or(&self.unlinked_settings, |item| &item.settings)
    }

    pub fn select_primary(&mut self) {
        if self
            .account(&self.primary_login)
            .is_some_and(|profile| profile.active)
        {
            return;
        }
        let login = self
            .active()
            .next()
            .or_else(|| self.accounts.first())
            .map(|profile| profile.login.clone())
            .unwrap_or_default();
        self.primary_login = login;
    }

    pub fn event(&self, id: &str) -> Option<&Meeting> {
        self.active()
            .find_map(|profile| {
                profile
                    .cache
                    .values()
                    .find_map(|entry| entry.meetings.get(id))
            })
            .or_else(|| {
                self.active().find_map(|profile| {
                    profile
                        .snoozes
                        .iter()
                        .map(|item| &item.meeting)
                        .chain(profile.activity.iter().map(|item| &item.meeting))
                        .find(|event| event.id == id)
                })
            })
    }

    pub fn coverage(&self) -> Vec<Range> {
        self.active()
            .filter(|profile| profile.visible)
            .flat_map(|profile| {
                profile
                    .calendars
                    .iter()
                    .filter(|calendar| calendar.visible && calendar.listed)
                    .map(|calendar| {
                        profile
                            .cache
                            .get(&calendar.info.id)
                            .map_or(&[][..], |entry| entry.coverage.as_slice())
                    })
            })
            .fold(None, |prior, ranges| {
                Some(prior.map_or_else(|| ranges.to_vec(), |left| intersect_ranges(left, ranges)))
            })
            .unwrap_or_default()
    }

    pub fn refresh_interval(&self, at: i64) -> i64 {
        use chrono::Timelike;
        let local = local_time(at);
        let minute = local.hour() * 60 + local.minute();
        let inside = local.weekday().number_from_monday() <= 5
            && self.preferences().workday_minutes().contains(&minute);
        (if inside {
            self.globals.workday_refresh_minutes
        } else {
            self.globals.outside_refresh_minutes
        }) * MINUTE
    }

    pub fn last_sync(&self) -> i64 {
        self.active()
            .map(|profile| profile.last_sync)
            .min()
            .unwrap_or(0)
    }

    pub fn warning(&self) -> String {
        self.active()
            .filter(|profile| !profile.error.is_empty())
            .map(|profile| format!("{} · {}", profile.name(), profile.error))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

pub fn is_declined(meeting: &Meeting, login: &str) -> bool {
    invitation_status(meeting, login).eq_ignore_ascii_case("declined")
}
