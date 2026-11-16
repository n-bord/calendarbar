use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{DateTime, Datelike, LocalResult, NaiveDate, NaiveDateTime, TimeZone, Timelike, Utc};
use chrono_tz::Tz;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::LazyLock,
    time::{Duration, Instant},
};
use url::Url;

pub const MINUTE: i64 = 60_000;
const HOUR: i64 = 60 * MINUTE;
pub const DAY: i64 = 24 * HOUR;
const TELEMOST_HOSTS: [&str; 4] = [
    "telemost.yandex.ru",
    "telemost.360.yandex.ru",
    "telemost.yandex.com",
    "telemost.360.yandex.com",
];
const YANDEX_HOSTS: [&str; 4] = [
    "calendar.yandex.ru",
    "calendar.360.yandex.ru",
    "calendar.yandex.com",
    "calendar.360.yandex.com",
];

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attendee {
    pub email: String,
    pub name: String,
    pub optional: bool,
    pub response: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct AllDayDates {
    pub start: String,
    pub end: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Meeting {
    pub id: String,
    #[serde(rename = "seriesID")]
    pub series_id: String,
    #[serde(rename = "calendarID")]
    pub calendar_id: String,
    pub calendar_name: String,
    pub account_login: Option<String>,
    pub title: String,
    pub start: i64,
    pub end: i64,
    pub all_day: bool,
    pub all_day_dates: Option<AllDayDates>,
    pub details: String,
    pub location: String,
    pub link: Option<String>,
    #[serde(default)]
    pub attendees: Vec<Attendee>,
    pub organizer: String,
    pub cancelled: bool,
    pub uid: String,
    pub recurrence_rule: Option<String>,
    pub original_start: Option<i64>,
    pub is_recurring: bool,
    #[serde(rename = "sourceURL")]
    pub source_url: Option<String>,
    #[serde(rename = "resourceURL")]
    pub resource_url: Option<String>,
    pub etag: Option<String>,
    pub is_free: bool,
}

#[derive(Clone, Copy)]
pub struct ParseOptions<'a> {
    pub calendar_id: &'a str,
    pub calendar_name: &'a str,
    pub account_login: &'a str,
    pub fallback_zone: Tz,
    pub display_zone: Option<Tz>,
    pub resource_url: Option<&'a str>,
    pub etag: Option<&'a str>,
    pub range: Option<(i64, i64)>,
}

pub fn local_zone() -> Tz {
    iana_time_zone::get_timezone()
        .ok()
        .and_then(|zone| zone.parse().ok())
        .unwrap_or(chrono_tz::UTC)
}

pub fn zoned_time(time: i64, zone: Tz) -> Option<DateTime<Tz>> {
    DateTime::<Utc>::from_timestamp_millis(time).map(|date| date.with_timezone(&zone))
}

fn civil_time(time: i64, zone: Tz) -> Option<i64> {
    zoned_time(time, zone).map(|date| date.naive_local().and_utc().timestamp_millis())
}

fn absolute_time(
    civil: i64,
    zone: Tz,
    preferred_offset: Option<i64>,
    next_valid: bool,
) -> Option<i64> {
    let date = DateTime::<Utc>::from_timestamp_millis(civil)?.naive_utc();
    match zone.from_local_datetime(&date) {
        LocalResult::Single(value) => Some(value.timestamp_millis()),
        LocalResult::Ambiguous(a, b) => {
            let a = a.timestamp_millis();
            let b = b.timestamp_millis();
            Some(match preferred_offset.map(|offset| civil - offset) {
                Some(preferred) if preferred == a || preferred == b => preferred,
                _ => a.min(b),
            })
        }
        LocalResult::None if next_valid => {
            // Reuse the offset immediately before the gap, preserving the position
            // within the skipped wall-clock hour.
            let before = civil.checked_sub(DAY)?;
            let offset = civil_time(before, zone)? - before;
            let result = civil.checked_sub(offset)?;
            (civil_time(result, zone)? > civil).then_some(result)
        }
        LocalResult::None => None,
    }
}

fn midnight(civil: i64) -> i64 {
    civil.div_euclid(DAY) * DAY
}

pub fn day_start(time: i64, zone: Tz) -> Option<i64> {
    absolute_time(midnight(civil_time(time, zone)?), zone, None, true)
}

pub fn add_calendar_days(start: i64, days: i64, zone: Tz) -> Option<i64> {
    if days == 0 {
        return Some(start);
    }
    let civil = civil_time(start, zone)?;
    let shifted = civil.checked_add(days.checked_mul(DAY)?)?;
    absolute_time(shifted, zone, Some(civil - start), true)
}

pub fn day_key(time: i64, zone: Tz) -> Option<String> {
    zoned_time(time, zone).map(|date| date.format("%Y-%m-%d").to_string())
}

pub fn displayed(mut meeting: Meeting, zone: Tz) -> Meeting {
    let midnight = |value: &str| {
        let date = NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()?;
        let instant = date.and_hms_opt(0, 0, 0)?.and_utc().timestamp_millis();
        absolute_time(instant, zone, None, true)
    };
    if let Some(dates) = meeting.all_day_dates.as_ref().filter(|_| meeting.all_day) {
        meeting.start = midnight(&dates.start).unwrap_or(meeting.start);
        meeting.end = midnight(&dates.end).unwrap_or(meeting.end);
    }
    meeting
}

pub fn overlaps(meeting: &Meeting, from: i64, to: i64) -> bool {
    meeting.start < to && (meeting.end > from || meeting.start >= from)
}

pub fn scoped_id(id: &str, login: &str) -> String {
    if login.is_empty() {
        id.to_owned()
    } else {
        format!("account:{}:{id}", STANDARD.encode(login))
    }
}

fn safe_web_url(value: &str) -> Option<Url> {
    let (scheme, rest) = value.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("http") && !scheme.eq_ignore_ascii_case("https") {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next()?;
    if authority.is_empty() || authority.contains(['@', '\\']) {
        return None;
    }
    let parsed = Url::parse(value).ok()?;
    if !parsed.username().is_empty() || parsed.password().is_some() || parsed.host_str().is_none() {
        return None;
    }
    Some(parsed)
}

fn has_explicit_port(value: &str) -> bool {
    value
        .split_once("://")
        .and_then(|(_, rest)| rest.split(['/', '?', '#']).next())
        .and_then(|authority| authority.rsplit_once(':'))
        .is_some_and(|(_, port)| !port.is_empty() && port.bytes().all(|part| part.is_ascii_digit()))
}

pub fn telemost_desktop_url(value: &str) -> Option<String> {
    let url = safe_web_url(value)?;
    let host = url.host_str()?;
    if !TELEMOST_HOSTS.contains(&host) || url.port().is_some() || has_explicit_port(value) {
        return None;
    }
    let mut path = url.path_segments()?.filter(|part| !part.is_empty());
    if path.next()? != "j" {
        return None;
    }
    let room = path.next()?;
    if path.next().is_some() || !room.bytes().all(|part| part.is_ascii_digit()) {
        return None;
    }
    Some(format!("telemost://https://{host}/j/{room}"))
}

pub fn browser_url(value: &str) -> String {
    if telemost_desktop_url(value).is_none() {
        return value.into();
    }
    let mut url = Url::parse(value).expect("Telemost URL has already been parsed");
    let old = url.query_pairs().into_owned().collect::<Vec<_>>();
    let mut query = url.query_pairs_mut();
    query.clear();
    let mut replaced = false;
    for (key, value) in old {
        if key != "skip_app" {
            query.append_pair(&key, &value);
        } else if !replaced {
            query.append_pair("skip_app", "1");
            replaced = true;
        }
    }
    if !replaced {
        query.append_pair("skip_app", "1");
    }
    drop(query);
    url.into()
}

pub fn is_usable_meeting_url(value: &str) -> bool {
    safe_web_url(value)
        .and_then(|url| url.host_str().map(str::to_owned))
        .is_some_and(|host| {
            !YANDEX_HOSTS.contains(&host.as_str())
                && host != "calendar.google.com"
                && (!TELEMOST_HOSTS.contains(&host.as_str())
                    || telemost_desktop_url(value).is_some())
        })
}

fn known_conference(value: &str) -> bool {
    if !is_usable_meeting_url(value) {
        return false;
    }
    let url = safe_web_url(value).expect("Meeting URL has already been parsed");
    let host = url.host_str().unwrap_or_default();
    let path = url.path().to_ascii_lowercase();
    if ["meet.google.com", "meet.jit.si"].contains(&host) {
        return path.len() > 1;
    }
    if ["zoom.us", "zoom.com"].contains(&host)
        || host.ends_with(".zoom.us")
        || host.ends_with(".zoom.com")
    {
        return ["/j/", "/my/", "/wc/"]
            .iter()
            .any(|prefix| path.starts_with(prefix));
    }
    if [
        "teams.microsoft.com",
        "teams.live.com",
        "teams.cloud.microsoft",
    ]
    .contains(&host)
    {
        return path.starts_with("/l/meetup-join/") || path.starts_with("/meet/");
    }
    host.ends_with(".webex.com")
        && (path.contains("/meet/")
            || path.contains("/join/")
            || url
                .query_pairs()
                .any(|(key, _)| key.eq_ignore_ascii_case("MTID")))
}

fn urls_in(text: &str) -> impl Iterator<Item = &str> {
    static URLS: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r#"(?i)https?://[^\s<>"]+"#).unwrap());
    URLS.find_iter(text)
        .map(|value| value.as_str().trim_end_matches([')', '.', ',', ';', ']']))
}

fn conference_url<'a>(explicit: &[&'a str], texts: &[&'a str]) -> Option<String> {
    let candidates = || {
        explicit
            .iter()
            .copied()
            .chain(texts.iter().flat_map(|text| urls_in(text)))
    };
    candidates()
        .find(|url| telemost_desktop_url(url).is_some())
        .or_else(|| candidates().find(|url| known_conference(url)))
        .or_else(|| {
            explicit
                .iter()
                .copied()
                .find(|url| is_usable_meeting_url(url))
        })
        .map(str::to_owned)
}

pub fn is_yandex_event_url(value: &str) -> bool {
    let Some(url) = safe_web_url(value) else {
        return false;
    };
    if url.scheme() != "https"
        || url.port().is_some()
        || has_explicit_port(value)
        || !YANDEX_HOSTS.contains(&url.host_str().unwrap_or_default())
    {
        return false;
    }
    let mut parts = url
        .path_segments()
        .into_iter()
        .flatten()
        .filter(|part| !part.is_empty());
    parts.any(|part| part == "event")
        && (parts.next().is_some()
            || url
                .query_pairs()
                .any(|(key, id)| key == "event_id" && !id.trim().is_empty()))
}

pub fn yandex_create_url(start: i64, end: Option<i64>, zone: Tz) -> Result<String, String> {
    let local =
        |date| zoned_time(date, zone).map(|value| value.format("%Y-%m-%dT%H:%M:%S").to_string());
    let invalid = || "Укажите корректную дату.".to_owned();
    let mut url = Url::parse("https://calendar.yandex.ru/week/create").unwrap();
    url.query_pairs_mut()
        .append_pair("show_date", &day_key(start, zone).ok_or_else(invalid)?)
        .append_pair("start", &local(start).ok_or_else(invalid)?)
        .append_pair(
            "end",
            &local(end.unwrap_or(start.saturating_add(30 * MINUTE))).ok_or_else(invalid)?,
        )
        .append_pair("tz_id", zone.name());
    Ok(url.into())
}

pub fn yandex_edit_url(meeting: &Meeting, zone: Tz) -> Result<String, String> {
    if let Some(exact) = meeting
        .source_url
        .as_ref()
        .filter(|value| is_yandex_event_url(value))
    {
        return Ok(exact.clone());
    }
    let date = meeting
        .all_day_dates
        .as_ref()
        .map(|dates| dates.start.clone())
        .or_else(|| day_key(meeting.start, zone))
        .ok_or_else(|| "Укажите корректную дату.".to_owned())?;
    let mut url = Url::parse("https://calendar.yandex.ru/day").unwrap();
    url.query_pairs_mut()
        .append_pair("show_date", &date)
        .append_pair("tz_id", zone.name());
    Ok(url.into())
}

pub fn invitation_status(meeting: &Meeting, login: &str) -> &'static str {
    let owner = meeting
        .account_login
        .as_deref()
        .filter(|value| !value.is_empty())
        .unwrap_or(login);
    if owner.is_empty() {
        return "unknown";
    }
    let same_login = |value: &str| {
        if owner.is_ascii() && value.is_ascii() {
            value.eq_ignore_ascii_case(owner)
        } else {
            value.to_lowercase() == owner.to_lowercase()
        }
    };
    if same_login(&meeting.organizer) {
        return "organizer";
    }
    match meeting
        .attendees
        .iter()
        .find(|person| same_login(&person.email))
        .map(|person| person.response.to_ascii_uppercase())
        .as_deref()
    {
        Some("ACCEPTED") => "accepted",
        Some("NEEDS-ACTION") => "needsAction",
        Some("TENTATIVE") => "tentative",
        Some("DECLINED") => "declined",
        _ => "unknown",
    }
}

#[derive(Clone, Debug)]
struct Property {
    name: String,
    parameters: BTreeMap<String, String>,
    value: String,
}

impl Property {
    fn bare(value: &str) -> Self {
        Self {
            name: String::new(),
            parameters: BTreeMap::new(),
            value: value.into(),
        }
    }

    fn parameter(&self, key: &str) -> Option<&str> {
        self.parameters.get(key).map(String::as_str)
    }
}

type Component = Vec<Property>;

fn read_property(line: &str) -> Option<Property> {
    let mut tokens = Vec::new();
    let mut quoted = false;
    let mut start = 0;
    for (index, character) in line.char_indices() {
        if character == '"' {
            quoted = !quoted;
        }
        if quoted || !matches!(character, ':' | ';') {
            continue;
        }
        tokens.push(&line[start..index]);
        if character == ':' {
            let name = tokens[0].to_ascii_uppercase();
            let parameters = tokens[1..]
                .iter()
                .filter_map(|token| {
                    let (key, value) = token.split_once('=')?;
                    let value = value
                        .strip_prefix('"')
                        .and_then(|value| value.strip_suffix('"'))
                        .unwrap_or(value);
                    Some((key.to_ascii_uppercase(), value.to_owned()))
                })
                .collect();
            return Some(Property {
                name,
                parameters,
                value: line[index + 1..].to_owned(),
            });
        }
        start = index + 1;
    }
    None
}

fn components_from(text: &str) -> Result<Vec<Component>, String> {
    let invalid = || "Сервер вернул повреждённые данные календаря.".to_owned();
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut lines = Vec::<String>::new();
    for line in normalized.lines() {
        if let Some(continuation) = line.strip_prefix(' ').or_else(|| line.strip_prefix('\t')) {
            if let Some(previous) = lines.last_mut() {
                previous.push_str(continuation);
                continue;
            }
        }
        lines.push(line.to_owned());
    }

    let mut components = Vec::new();
    let mut current = None::<Component>;
    let mut nested = 0usize;
    let mut calendar = false;
    for line in lines {
        match line.to_ascii_uppercase().as_str() {
            "BEGIN:VCALENDAR" => calendar = true,
            "BEGIN:VEVENT" => {
                if current.is_some() {
                    return Err(invalid());
                }
                current = Some(Vec::new());
                nested = 0;
            }
            "END:VEVENT" => {
                if let Some(event) = current.take() {
                    components.push(event);
                }
            }
            _ if current.is_some() => {
                let upper = line.to_ascii_uppercase();
                if upper.starts_with("BEGIN:") {
                    nested += 1;
                } else if upper.starts_with("END:") {
                    nested = nested.saturating_sub(1);
                } else if nested == 0 {
                    if let Some(property) = read_property(&line) {
                        current.as_mut().unwrap().push(property);
                    }
                }
            }
            _ => {}
        }
    }
    if !calendar || current.is_some() {
        return Err(invalid());
    }
    Ok(components)
}

fn first<'a>(component: &'a [Property], name: &str) -> Option<&'a Property> {
    component.iter().find(|item| item.name == name)
}

fn all<'a>(component: &'a [Property], name: &'a str) -> impl Iterator<Item = &'a Property> {
    component.iter().filter(move |item| item.name == name)
}

fn all_day(property: Option<&Property>) -> bool {
    property.is_some_and(|property| {
        property
            .parameter("VALUE")
            .is_some_and(|value| value.eq_ignore_ascii_case("DATE"))
            || (property.value.len() == 8
                && property.value.bytes().all(|part| part.is_ascii_digit()))
    })
}

fn decode(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut characters = text.chars();
    while let Some(character) = characters.next() {
        if character != '\\' {
            result.push(character);
        } else {
            match characters.next() {
                Some('n' | 'N') => result.push('\n'),
                Some(escaped) => result.push(escaped),
                None => result.push('\\'),
            }
        }
    }
    result
}

fn event_zone(property: &Property, fallback: Tz) -> Result<Tz, String> {
    if property.value.ends_with(['Z', 'z']) {
        return Ok(chrono_tz::UTC);
    }
    match property.parameter("TZID").filter(|name| !name.is_empty()) {
        Some(name) => name
            .parse()
            .map_err(|_| format!("Неизвестный часовой пояс {name}.")),
        None => Ok(fallback),
    }
}

fn required_date(property: Option<&Property>, fallback: Tz, message: &str) -> Result<i64, String> {
    let invalid = || message.to_owned();
    let property = property.ok_or_else(invalid)?;
    let zone = event_zone(property, fallback)?;
    let uppercase = property.value.to_ascii_uppercase();
    let bytes = uppercase.as_bytes();
    let date = match bytes.len() {
        8 if bytes.iter().all(u8::is_ascii_digit) => {
            NaiveDate::parse_from_str(&uppercase, "%Y%m%d")
                .ok()
                .and_then(|date| date.and_hms_opt(0, 0, 0))
        }
        15 | 16
            if bytes[8] == b'T'
                && bytes[13] <= b'5'
                && bytes[..8]
                    .iter()
                    .chain(&bytes[9..15])
                    .all(u8::is_ascii_digit)
                && (bytes.len() == 15 || bytes[15] == b'Z') =>
        {
            NaiveDateTime::parse_from_str(
                uppercase.strip_suffix('Z').unwrap_or(&uppercase),
                "%Y%m%dT%H%M%S",
            )
            .ok()
        }
        _ => None,
    }
    .ok_or_else(invalid)?;
    absolute_time(date.and_utc().timestamp_millis(), zone, None, false).ok_or_else(invalid)
}

#[derive(Clone, Copy, Default)]
struct Length {
    days: i64,
    milliseconds: i64,
}

fn calendar_difference(start: i64, end: i64, zone: Tz) -> Option<Length> {
    let direction = (end - start).signum();
    let mut days = (midnight(civil_time(end, zone)?) - midnight(civil_time(start, zone)?)) / DAY;
    let mut intermediate = add_calendar_days(start, days, zone)?;
    if (intermediate - end) * direction > 0 {
        days -= direction;
        intermediate = add_calendar_days(start, days, zone)?;
    }
    Some(Length {
        days,
        milliseconds: end - intermediate,
    })
}

fn end_after(start: i64, length: Length, zone: Tz) -> Result<i64, String> {
    add_calendar_days(start, length.days, zone)
        .and_then(|end| end.checked_add(length.milliseconds))
        .filter(|end| DateTime::<Utc>::from_timestamp_millis(*end).is_some())
        .ok_or_else(|| "Не удалось вычислить дату встречи.".to_owned())
}

fn length_of(component: &[Property], start: i64, zone: Tz) -> Result<Length, String> {
    let all_day =
        all_day(first(component, "DTSTART").or_else(|| first(component, "RECURRENCE-ID")));
    if let Some(property) = first(component, "DTEND") {
        let message = "Некорректное время окончания встречи.";
        let end = required_date(Some(property), zone, message)?;
        if end < start {
            return Err(message.into());
        }
        if all_day {
            let days = calendar_difference(start, end, zone).ok_or(message)?.days;
            return Ok(Length {
                days,
                milliseconds: 0,
            });
        }
        return Ok(Length {
            days: 0,
            milliseconds: end - start,
        });
    }
    let Some(duration) = first(component, "DURATION").filter(|value| !value.value.is_empty())
    else {
        return Ok(Length {
            days: i64::from(all_day),
            milliseconds: 0,
        });
    };
    static DURATION: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(
            r"^P(?:([0-9]+)W)?(?:([0-9]+)D)?(?:T(?:([0-9]+)H)?(?:([0-9]+)M)?(?:([0-9]+)S)?)?$",
        )
        .unwrap()
    });
    let invalid = || "Неизвестный формат длительности встречи.".to_owned();
    let parts = DURATION.captures(&duration.value).ok_or_else(invalid)?;
    if !(1..=5).any(|index| parts.get(index).is_some()) {
        return Err(invalid());
    }
    let number = |index| {
        parts
            .get(index)
            .map_or(Ok(0), |value| value.as_str().parse::<i64>())
    };
    let values = (1..=5)
        .map(number)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| invalid())?;
    let days = values[0]
        .checked_mul(7)
        .and_then(|weeks| weeks.checked_add(values[1]))
        .ok_or_else(invalid)?;
    let milliseconds = values[2]
        .checked_mul(HOUR)
        .and_then(|hours| hours.checked_add(values[3].checked_mul(MINUTE)?))
        .and_then(|partial| partial.checked_add(values[4].checked_mul(1000)?))
        .ok_or_else(invalid)?;
    Ok(Length { days, milliseconds })
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Frequency {
    Minutely,
    Hourly,
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

struct Rule {
    frequency: Frequency,
    interval: i64,
    count: Option<usize>,
    until: Option<i64>,
    week_start: i64,
    months: Vec<i64>,
    month_days: Vec<i64>,
    year_days: Vec<i64>,
    week_numbers: Vec<i64>,
    days: Vec<(i64, Option<i64>)>,
    hours: Vec<i64>,
    minutes: Vec<i64>,
    seconds: Vec<i64>,
    positions: Vec<i64>,
}

fn recurrence_rule(raw: &str, zone: Tz) -> Result<Rule, String> {
    let uppercase = raw.to_ascii_uppercase();
    let mut fields = BTreeMap::new();
    for item in uppercase.split(';') {
        let (key, value) = item
            .split_once('=')
            .filter(|(key, value)| !key.is_empty() && !value.is_empty() && !value.contains('='))
            .ok_or("Некорректное правило повторения встречи.")?;
        if !matches!(
            key,
            "FREQ"
                | "INTERVAL"
                | "COUNT"
                | "UNTIL"
                | "WKST"
                | "BYMONTH"
                | "BYMONTHDAY"
                | "BYYEARDAY"
                | "BYWEEKNO"
                | "BYDAY"
                | "BYHOUR"
                | "BYMINUTE"
                | "BYSECOND"
                | "BYSETPOS"
        ) {
            return Err(format!("Параметр повторения {key} пока не поддерживается."));
        }
        if fields.insert(key, value).is_some() {
            return Err("Некорректное правило повторения встречи.".into());
        }
    }

    let read = |key| fields.get(key).copied();
    let frequency = match read("FREQ") {
        Some("MINUTELY") => Frequency::Minutely,
        Some("HOURLY") => Frequency::Hourly,
        Some("DAILY") => Frequency::Daily,
        Some("WEEKLY") => Frequency::Weekly,
        Some("MONTHLY") => Frequency::Monthly,
        Some("YEARLY") => Frequency::Yearly,
        value => {
            return Err(format!(
                "Неизвестная частота повторения: {}.",
                value.unwrap_or("не указана")
            ))
        }
    };
    let number = |value: &str, key, min, max, skip_zero: bool| {
        value
            .parse::<i64>()
            .ok()
            .filter(|number| (min..=max).contains(number) && (!skip_zero || *number != 0))
            .ok_or_else(|| format!("Некорректный параметр повторения {key}."))
    };
    let list = |key, min, max, skip_zero| -> Result<Vec<i64>, String> {
        let mut numbers = read(key)
            .into_iter()
            .flat_map(|value| value.split(','))
            .map(|value| number(value, key, min, max, skip_zero))
            .collect::<Result<Vec<_>, _>>()?;
        numbers.sort_unstable();
        numbers.dedup();
        Ok(numbers)
    };
    let weekdays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
    let weekday = |name: &str| {
        weekdays
            .iter()
            .position(|value| *value == name)
            .map(|day| day as i64)
    };
    let week_start =
        weekday(read("WKST").unwrap_or("MO")).ok_or("Некорректное начало недели WKST.")?;
    let interval = number(
        read("INTERVAL").unwrap_or("1"),
        "INTERVAL",
        1,
        1_000_000,
        false,
    )?;
    if read("COUNT").is_some() && read("UNTIL").is_some() {
        return Err("Правило встречи одновременно содержит COUNT и UNTIL.".into());
    }
    let count = read("COUNT")
        .map(|value| number(value, "COUNT", 1, 1_000_000, false))
        .transpose()?
        .map(|value| value as usize);
    let until = if let Some(value) = read("UNTIL") {
        let until = required_date(
            Some(&Property::bare(value)),
            zone,
            "Некорректная граница повторения UNTIL.",
        )?;
        Some(if value.len() == 8 {
            end_after(
                until,
                Length {
                    days: 1,
                    milliseconds: -1,
                },
                zone,
            )?
        } else {
            until
        })
    } else {
        None
    };

    let months = list("BYMONTH", 1, 12, false)?;
    let month_days = list("BYMONTHDAY", -31, 31, true)?;
    let year_days = list("BYYEARDAY", -366, 366, true)?;
    let week_numbers = list("BYWEEKNO", -53, 53, true)?;
    let hours = list("BYHOUR", 0, 23, false)?;
    let minutes = list("BYMINUTE", 0, 59, false)?;
    let seconds = list("BYSECOND", 0, 59, false)?;
    let positions = list("BYSETPOS", -366, 366, true)?;
    let days = read("BYDAY")
        .into_iter()
        .flat_map(|value| value.split(','))
        .map(|value| {
            let tail = value
                .len()
                .checked_sub(2)
                .ok_or("Некорректный день недели в повторении BYDAY.")?;
            let day = value
                .get(tail..)
                .and_then(weekday)
                .ok_or("Некорректный день недели в повторении BYDAY.")?;
            let prefix = &value[..tail];
            if !prefix.is_empty() && !matches!(frequency, Frequency::Monthly | Frequency::Yearly) {
                return Err("Некорректный порядковый номер дня BYDAY.".to_owned());
            }
            let ordinal = (!prefix.is_empty())
                .then(|| number(prefix, "BYDAY", -53, 53, true))
                .transpose()?;
            Ok((day, ordinal))
        })
        .collect::<Result<Vec<_>, String>>()?;
    if frequency == Frequency::Weekly && !month_days.is_empty() {
        return Err("BYMONTHDAY нельзя использовать с WEEKLY.".into());
    }
    if frequency != Frequency::Yearly && !week_numbers.is_empty() {
        return Err("BYWEEKNO требует частоты YEARLY.".into());
    }
    if matches!(
        frequency,
        Frequency::Daily | Frequency::Weekly | Frequency::Monthly
    ) && !year_days.is_empty()
    {
        return Err("BYYEARDAY несовместим с указанной частотой.".into());
    }
    Ok(Rule {
        frequency,
        interval,
        count,
        until,
        week_start,
        months,
        month_days,
        year_days,
        week_numbers,
        days,
        hours,
        minutes,
        seconds,
        positions,
    })
}

fn naive(civil: i64) -> Option<NaiveDateTime> {
    DateTime::<Utc>::from_timestamp_millis(civil).map(|value| value.naive_utc())
}

// Month is indexed from zero. Overflow rolls into the adjacent year/month.
fn civil_date(year: i64, month: i64, day: u32) -> Option<i64> {
    let year = i32::try_from(year.checked_add(month.div_euclid(12))?).ok()?;
    let month = month.rem_euclid(12) as u32 + 1;
    Some(
        NaiveDate::from_ymd_opt(year, month, day)?
            .and_hms_opt(0, 0, 0)?
            .and_utc()
            .timestamp_millis(),
    )
}

fn week_of(civil: i64, first_day: i64) -> Option<i64> {
    let day = i64::from(naive(civil)?.weekday().num_days_from_sunday());
    Some(midnight(civil) - (day - first_day).rem_euclid(7) * DAY)
}

fn first_week_of_year(year: i64, first_day: i64) -> Option<i64> {
    week_of(civil_date(year, 0, 4)?, first_day)
}

fn period_index(civil: i64, rule: &Rule) -> Option<i64> {
    Some(match rule.frequency {
        Frequency::Daily => civil.div_euclid(DAY),
        Frequency::Weekly => {
            (week_of(civil, rule.week_start)? - week_of(0, rule.week_start)?) / (7 * DAY)
        }
        Frequency::Monthly => {
            let date = naive(civil)?;
            i64::from(date.year()) * 12 + i64::from(date.month0())
        }
        _ => i64::from(naive(civil)?.year()),
    })
}

fn period_bounds(period: i64, rule: &Rule) -> Option<(i64, i64)> {
    Some(match rule.frequency {
        Frequency::Daily => (period * DAY, (period + 1) * DAY),
        Frequency::Weekly => {
            let start = week_of(0, rule.week_start)? + period * 7 * DAY;
            (start, start + 7 * DAY)
        }
        Frequency::Monthly => {
            let year = period.div_euclid(12);
            let month = period.rem_euclid(12);
            (civil_date(year, month, 1)?, civil_date(year, month + 1, 1)?)
        }
        Frequency::Yearly if !rule.week_numbers.is_empty() => (
            first_week_of_year(period, rule.week_start)?,
            first_week_of_year(period + 1, rule.week_start)?,
        ),
        _ => (civil_date(period, 0, 1)?, civil_date(period + 1, 0, 1)?),
    })
}

fn matches_ordinal(options: &[i64], index: i64, size: i64) -> bool {
    options.is_empty() || options.contains(&index) || options.contains(&(index - size - 1))
}

fn matches_date(
    civil: i64,
    base: NaiveDateTime,
    rule: &Rule,
    period: i64,
    start: i64,
    end: i64,
) -> Option<bool> {
    let date = naive(civil)?;
    let year = i64::from(date.year());
    let month = i64::from(date.month0());
    let day = i64::from(date.day());
    let year_start = civil_date(year, 0, 1)?;
    let year_end = civil_date(year + 1, 0, 1)?;
    let month_length = (civil_date(year, month + 1, 1)? - civil_date(year, month, 1)?) / DAY;
    if (!rule.months.is_empty() && !rule.months.contains(&(month + 1)))
        || !matches_ordinal(&rule.month_days, day, month_length)
        || !matches_ordinal(
            &rule.year_days,
            (civil - year_start) / DAY + 1,
            (year_end - year_start) / DAY,
        )
        || !matches_ordinal(
            &rule.week_numbers,
            (civil - start).div_euclid(7 * DAY) + 1,
            (end - start) / (7 * DAY),
        )
    {
        return Some(false);
    }
    let weekday = i64::from(date.weekday().num_days_from_sunday());
    if !rule.days.is_empty() {
        let matches = rule.days.iter().any(|(requested, ordinal)| {
            if *requested != weekday {
                return false;
            }
            let Some(ordinal) = ordinal else {
                return true;
            };
            let in_year = rule.frequency == Frequency::Yearly
                && rule.months.is_empty()
                && rule.week_numbers.is_empty();
            let index = if in_year {
                (civil - year_start) / DAY
            } else {
                day - 1
            };
            let after = if in_year {
                (year_end - civil) / DAY - 1
            } else {
                month_length - day
            };
            *ordinal == index / 7 + 1 || *ordinal == -after / 7 - 1
        });
        if !matches {
            return Some(false);
        }
    } else if rule.frequency == Frequency::Weekly {
        return Some(date.weekday() == base.weekday());
    }
    let expanded = !rule.days.is_empty()
        || !rule.month_days.is_empty()
        || !rule.year_days.is_empty()
        || !rule.week_numbers.is_empty();
    if !expanded && rule.frequency == Frequency::Monthly {
        return Some(date.day() == base.day());
    }
    if !expanded && rule.frequency == Frequency::Yearly {
        return Some(
            year == period
                && date.day() == base.day()
                && (!rule.months.is_empty() || date.month() == base.month()),
        );
    }
    Some(true)
}

fn with_default(list: &[i64], default: i64) -> Vec<i64> {
    if list.is_empty() {
        vec![default]
    } else {
        list.to_vec()
    }
}

fn recurrence_dates(
    raw: &str,
    start: i64,
    zone: Tz,
    from: i64,
    to: i64,
) -> Result<Vec<i64>, String> {
    let rule = recurrence_rule(raw, zone)?;
    let invalid = || "Не удалось вычислить дату встречи.".to_owned();
    let too_many =
        || "Правило встречи создаёт слишком много повторов. Расчёт остановлен.".to_owned();
    let civil_start = civil_time(start, zone).ok_or_else(invalid)?;
    let base = naive(civil_start).ok_or_else(invalid)?;
    let elapsed_step = match rule.frequency {
        Frequency::Minutely => MINUTE,
        Frequency::Hourly => HOUR,
        _ => 0,
    };
    let period_origin = if elapsed_step != 0 {
        start - civil_start.rem_euclid(elapsed_step)
    } else {
        start
    };
    let period_at = |time: i64, padding: i64| {
        if elapsed_step != 0 {
            Some((time - period_origin).div_euclid(elapsed_step))
        } else {
            period_index(civil_time(time + padding, zone)?, &rule)
        }
    };
    let original_period = period_at(start, 0).ok_or_else(invalid)?;
    let limit = (to - 1).min(rule.until.unwrap_or(to));
    if limit < start || from > limit {
        return Ok(Vec::new());
    }
    let first_period = period_at(from, -2 * DAY).ok_or_else(invalid)?;
    let last_period = period_at(limit, 2 * DAY).ok_or_else(invalid)?;
    let first_index = if rule.count.is_some() {
        0
    } else {
        ((first_period - original_period).div_euclid(rule.interval)).max(0)
    };
    let mut result = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut count = 0;
    let mut examined = 0;
    let seconds = with_default(&rule.seconds, i64::from(base.second()));
    for index in first_index.. {
        let period = original_period + index * rule.interval;
        if period > last_period {
            break;
        }
        if Instant::now() >= deadline {
            return Err(too_many());
        }
        let clock_period = period_origin + period * elapsed_step;
        let (first_time, period_end) = if elapsed_step == 0 {
            period_bounds(period, &rule).ok_or_else(invalid)?
        } else {
            let clock = civil_time(clock_period, zone).ok_or_else(invalid)?;
            (clock, clock + elapsed_step)
        };
        let first = naive(first_time).ok_or_else(invalid)?;
        let fixed_minute = elapsed_step == MINUTE;
        let fixed_hour = elapsed_step != 0;
        let hours = if fixed_hour {
            vec![i64::from(first.hour())]
        } else {
            with_default(&rule.hours, i64::from(base.hour()))
        };
        let minutes = if fixed_minute {
            vec![i64::from(first.minute())]
        } else {
            with_default(&rule.minutes, i64::from(base.minute()))
        };
        let mut candidates = Vec::new();
        for day in (midnight(first_time)..period_end).step_by(DAY as usize) {
            if !matches_date(day, base, &rule, period, first_time, period_end)
                .ok_or_else(invalid)?
            {
                continue;
            }
            for &hour in &hours {
                if fixed_hour && !rule.hours.is_empty() && !rule.hours.contains(&hour) {
                    continue;
                }
                for &minute in &minutes {
                    if fixed_minute && !rule.minutes.is_empty() && !rule.minutes.contains(&minute) {
                        continue;
                    }
                    for &second in &seconds {
                        examined += 1;
                        if examined > 500_000 || Instant::now() >= deadline {
                            return Err(too_many());
                        }
                        let absolute = if elapsed_step != 0 {
                            Some(
                                clock_period
                                    + if fixed_minute { 0 } else { minute * MINUTE }
                                    + second * 1000,
                            )
                        } else {
                            absolute_time(
                                day + hour * HOUR + minute * MINUTE + second * 1000,
                                zone,
                                None,
                                false,
                            )
                        };
                        if let Some(date) = absolute {
                            candidates.push(date);
                        }
                    }
                }
            }
        }
        candidates.sort_unstable();
        if !rule.positions.is_empty() {
            candidates = rule
                .positions
                .iter()
                .filter_map(|position| {
                    let index = if *position < 0 {
                        candidates.len() as i64 + position
                    } else {
                        position - 1
                    };
                    usize::try_from(index)
                        .ok()
                        .and_then(|index| candidates.get(index))
                        .copied()
                })
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect();
        }
        for date in candidates {
            if date < start {
                continue;
            }
            if date > limit {
                return Ok(result);
            }
            if date >= from {
                result.push(date);
            }
            count += 1;
            if Some(count) == rule.count {
                return Ok(result);
            }
            if result.len() >= 50_000 {
                return Err(too_many());
            }
        }
    }
    Ok(result)
}

fn email(value: &str) -> String {
    if value
        .get(..7)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("mailto:"))
    {
        value[7..].into()
    } else {
        value.into()
    }
}

struct Occurrence {
    start: i64,
    original: Option<i64>,
    zone: Tz,
    length: Length,
}

fn make_meeting(
    component: &[Property],
    master: &[Property],
    occurrence: Occurrence,
    uid: &str,
    options: ParseOptions<'_>,
) -> Result<Meeting, String> {
    let property = |name| first(component, name).or_else(|| first(master, name));
    let value = |name| property(name).map(|property| property.value.as_str());
    let all_day = all_day(property("DTSTART").or_else(|| property("RECURRENCE-ID")));
    let people = if first(component, "ATTENDEE").is_some() {
        component
    } else {
        master
    };
    let attendees = all(people, "ATTENDEE")
        .map(|item| Attendee {
            email: email(&item.value),
            name: decode(item.parameter("CN").unwrap_or_default()),
            optional: item
                .parameter("ROLE")
                .is_some_and(|role| role.eq_ignore_ascii_case("OPT-PARTICIPANT")),
            response: item
                .parameter("PARTSTAT")
                .unwrap_or("NEEDS-ACTION")
                .to_ascii_uppercase(),
        })
        .collect();
    let details = decode(value("DESCRIPTION").unwrap_or_default());
    let location = decode(value("LOCATION").unwrap_or_default());
    let urls = urls_in(value("URL").unwrap_or_default()).collect::<Vec<_>>();
    let conferences = if first(component, "CONFERENCE").is_some() {
        component
    } else {
        master
    };
    let explicit = all(conferences, "CONFERENCE")
        .flat_map(|item| urls_in(&item.value))
        .chain(urls.iter().copied())
        .collect::<Vec<_>>();
    let link = conference_url(&explicit, &[&location, &details]);
    let series = format!("{}|{uid}", options.calendar_id);
    let suffix = occurrence
        .original
        .map(|date| format!("{:.1}", date as f64 / 1000.0))
        .unwrap_or_else(|| "master".into());
    let end = end_after(occurrence.start, occurrence.length, occurrence.zone)?;
    let all_day_dates = if all_day {
        let invalid = || "Не удалось вычислить дату встречи на весь день.".to_owned();
        Some(AllDayDates {
            start: day_key(occurrence.start, occurrence.zone).ok_or_else(invalid)?,
            end: day_key(end, occurrence.zone).ok_or_else(invalid)?,
        })
    } else {
        None
    };
    let recurrence_rule = value("RRULE").map(str::to_owned);
    let meeting = Meeting {
        id: scoped_id(&format!("{series}|{suffix}"), options.account_login),
        series_id: scoped_id(&series, options.account_login),
        calendar_id: scoped_id(options.calendar_id, options.account_login),
        calendar_name: options.calendar_name.to_owned(),
        account_login: (!options.account_login.is_empty())
            .then(|| options.account_login.to_owned()),
        title: decode(value("SUMMARY").unwrap_or("Без названия")),
        start: occurrence.start,
        end,
        all_day,
        all_day_dates,
        details,
        location,
        link,
        attendees,
        organizer: email(value("ORGANIZER").unwrap_or_default()),
        cancelled: value("STATUS").is_some_and(|status| status.eq_ignore_ascii_case("CANCELLED")),
        uid: uid.to_owned(),
        is_recurring: occurrence.original.is_some()
            || recurrence_rule
                .as_ref()
                .is_some_and(|rule| !rule.is_empty()),
        recurrence_rule,
        original_start: occurrence.original,
        source_url: urls
            .into_iter()
            .find(|url| is_yandex_event_url(url))
            .map(str::to_owned),
        resource_url: options.resource_url.map(str::to_owned),
        etag: options.etag.map(str::to_owned),
        is_free: value("TRANSP").is_some_and(|status| status.eq_ignore_ascii_case("TRANSPARENT")),
    };
    Ok(match options.display_zone {
        Some(zone) => displayed(meeting, zone),
        None => meeting,
    })
}

fn date_list(component: &[Property], name: &str, zone: Tz) -> Result<BTreeSet<i64>, String> {
    let message = format!("Не удалось прочитать дату {name}.");
    all(component, name)
        .flat_map(|property| {
            property
                .value
                .split(',')
                .map(move |value| (property, value))
        })
        .map(|(property, value)| {
            if value.contains('/') {
                return Err("RDATE с периодом пока не поддерживается.".into());
            }
            let mut property = property.clone();
            property.value = value.to_owned();
            required_date(Some(&property), zone, &message)
        })
        .collect()
}

struct Override<'a> {
    component: &'a [Property],
    sequence: f64,
    moved: i64,
    following: bool,
}

fn expand_series(
    components: &[Component],
    uid: &str,
    options: ParseOptions<'_>,
) -> Result<Vec<Meeting>, String> {
    let within = |meeting: &Meeting| {
        options
            .range
            .is_none_or(|(from, to)| overlaps(meeting, from, to))
    };
    let fallback = options.fallback_zone;
    let mut masters = components
        .iter()
        .filter(|component| first(component, "RECURRENCE-ID").is_none());
    let master = masters.next();
    if masters.next().is_some() {
        return Err("Несколько основных записей одной серии.".into());
    }
    let sequence = |component: &[Property]| {
        first(component, "SEQUENCE")
            .and_then(|item| item.value.parse::<f64>().ok())
            .filter(|value| value.is_finite())
            .unwrap_or(0.0)
    };

    let Some(master) = master else {
        let mut instances = BTreeMap::<i64, (f64, Meeting)>::new();
        for component in components {
            let recurrence = first(component, "RECURRENCE-ID");
            let original =
                required_date(recurrence, fallback, "Не удалось прочитать RECURRENCE-ID.")?;
            let property = first(component, "DTSTART")
                .or(recurrence)
                .ok_or("Не удалось прочитать дату повтора.")?;
            let zone = event_zone(property, fallback)?;
            let start = required_date(Some(property), zone, "Не удалось прочитать дату повтора.")?;
            let sequence = sequence(component);
            if instances
                .get(&original)
                .is_none_or(|(previous, _)| *previous <= sequence)
            {
                let occurrence = Occurrence {
                    start,
                    original: Some(original),
                    zone,
                    length: length_of(component, start, zone)?,
                };
                instances.insert(
                    original,
                    (
                        sequence,
                        make_meeting(component, &[], occurrence, uid, options)?,
                    ),
                );
            }
        }
        return Ok(instances
            .into_values()
            .map(|(_, meeting)| meeting)
            .filter(within)
            .collect());
    };

    let starter = first(master, "DTSTART").ok_or("Не удалось прочитать начало встречи.")?;
    let start = required_date(
        Some(starter),
        fallback,
        "Не удалось прочитать начало встречи.",
    )?;
    let zone = event_zone(starter, fallback)?;
    let master_length = length_of(master, start, zone)?;
    let recurring = components.len() > 1
        || master
            .iter()
            .any(|item| matches!(item.name.as_str(), "RRULE" | "RDATE" | "EXDATE" | "EXRULE"));
    if !recurring {
        let occurrence = Occurrence {
            start,
            original: None,
            zone,
            length: master_length,
        };
        let meeting = make_meeting(master, &[], occurrence, uid, options)?;
        return Ok(Some(meeting).into_iter().filter(within).collect());
    }

    let (from, to) = options
        .range
        .ok_or("Для повторяющейся встречи нужен диапазон загрузки.")?;
    if first(master, "EXRULE").is_some() {
        return Err("Устаревшее исключение EXRULE пока не поддерживается.".into());
    }
    let mut rules = all(master, "RRULE");
    let rule = rules.next();
    if rules.next().is_some() {
        return Err("Несколько RRULE в одной серии пока не поддерживаются.".into());
    }
    let mut overrides = BTreeMap::<i64, Override<'_>>::new();
    let mut move_padding = 0;
    for component in components {
        let Some(property) = first(component, "RECURRENCE-ID") else {
            continue;
        };
        let original = required_date(Some(property), zone, "Некорректная дата исключения серии.")?;
        let range = property
            .parameter("RANGE")
            .filter(|value| !value.is_empty());
        if range.is_some_and(|value| !value.eq_ignore_ascii_case("THISANDFUTURE")) {
            return Err("Неизвестный вариант переноса RANGE.".into());
        }
        let sequence = sequence(component);
        if overrides
            .get(&original)
            .is_some_and(|previous| sequence < previous.sequence)
        {
            continue;
        }
        let moved = first(component, "DTSTART")
            .map(|property| {
                required_date(
                    Some(property),
                    zone,
                    "Не удалось прочитать перенесённое начало встречи.",
                )
            })
            .transpose()?
            .unwrap_or(original);
        move_padding = move_padding.max((moved - original).abs());
        overrides.insert(
            original,
            Override {
                component,
                sequence,
                moved,
                following: range.is_some(),
            },
        );
    }

    let date_padding = if all_day(Some(starter)) && options.display_zone.is_some() {
        2 * DAY
    } else {
        DAY
    };
    let duration = end_after(start, master_length, zone)? - start;
    let search_start = from - duration - move_padding - date_padding;
    let search_end = to + move_padding + date_padding;
    let mut dates = date_list(master, "RDATE", zone)?;
    dates.insert(start);
    dates.extend(overrides.keys().copied());
    if let Some(rule) = rule {
        dates.extend(recurrence_dates(
            &rule.value,
            start,
            zone,
            search_start,
            search_end,
        )?);
    }
    let excluded = date_list(master, "EXDATE", zone)?;
    let mut meetings = Vec::new();
    let mut following = None;
    for original in dates {
        let exact = overrides.get(&original);
        if let Some(exact) = exact.filter(|value| value.following) {
            let shift = calendar_difference(original, exact.moved, zone)
                .ok_or("Не удалось вычислить перенос встреч серии.")?;
            following = Some((exact, shift));
        }
        if excluded.contains(&original) && exact.is_none() {
            continue;
        }
        let overrides = exact.or(following.map(|(follow, _)| follow));
        let component = overrides.map_or(master.as_slice(), |value| value.component);
        let occurrence_start = if let Some(exact) = exact {
            exact.moved
        } else if let Some((_, shift)) = following {
            end_after(original, shift, zone)?
        } else {
            original
        };
        let length = match overrides {
            Some(exact)
                if first(component, "DTEND").is_some()
                    || first(component, "DURATION").is_some() =>
            {
                length_of(component, exact.moved, zone)?
            }
            _ => master_length,
        };
        let occurrence = Occurrence {
            start: occurrence_start,
            original: Some(original),
            zone,
            length,
        };
        let meeting = make_meeting(component, master, occurrence, uid, options)?;
        if within(&meeting) {
            meetings.push(meeting);
        }
    }
    Ok(meetings)
}

pub fn parse_icalendar(text: &str, options: ParseOptions<'_>) -> Result<Vec<Meeting>, String> {
    if options.range.is_some_and(|(start, end)| {
        end < start
            || zoned_time(start, options.fallback_zone).is_none()
            || zoned_time(end, options.fallback_zone).is_none()
    }) {
        return Err("Некорректный диапазон загрузки календаря.".into());
    }
    let mut groups = BTreeMap::<String, Vec<Component>>::new();
    for component in components_from(text)? {
        let uid = first(&component, "UID")
            .filter(|item| !item.value.is_empty())
            .ok_or("Не удалось прочитать UID встречи.")?
            .value
            .clone();
        groups.entry(uid).or_default().push(component);
    }
    let mut meetings = Vec::new();
    for (uid, components) in groups {
        meetings.extend(expand_series(&components, &uid, options).map_err(|error| {
            let title = decode(
                first(&components[0], "SUMMARY")
                    .map(|item| item.value.as_str())
                    .unwrap_or("Без названия"),
            );
            format!("Встреча «{title}»: {error}")
        })?);
    }
    meetings.sort_by(|a, b| a.start.cmp(&b.start).then_with(|| a.id.cmp(&b.id)));
    Ok(meetings)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn time(value: &str) -> i64 {
        DateTime::parse_from_rfc3339(value)
            .unwrap()
            .timestamp_millis()
    }

    fn utc(value: &str) -> i64 {
        time(&format!("{value}:00Z"))
    }

    fn event(properties: &str) -> String {
        format!("BEGIN:VEVENT\nUID:series\n{properties}\nEND:VEVENT")
    }

    fn options() -> ParseOptions<'static> {
        ParseOptions {
            calendar_id: "work",
            calendar_name: "Рабочий",
            account_login: "",
            fallback_zone: chrono_tz::UTC,
            display_zone: None,
            resource_url: None,
            etag: None,
            range: Some((utc("2026-10-01T00:00"), utc("2026-12-01T00:00"))),
        }
    }

    fn parse(events: &str, options: ParseOptions<'_>) -> Result<Vec<Meeting>, String> {
        parse_icalendar(
            &format!("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n{events}\r\nEND:VCALENDAR"),
            options,
        )
    }

    fn expect_starts(properties: &str, expected: &[&str]) {
        let meetings = parse(&event(properties), options()).unwrap();
        assert_eq!(starts(&meetings), expected);
    }

    fn starts(meetings: &[Meeting]) -> Vec<String> {
        meetings
            .iter()
            .map(|meeting| {
                zoned_time(meeting.start, chrono_tz::UTC)
                    .unwrap()
                    .format("%Y-%m-%dT%H:%M")
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn monthly_set_positions_and_ordinals_use_complete_periods() {
        let input = event(
            "DTSTART:20260930T100000Z\nRRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=2",
        );
        assert_eq!(
            starts(&parse(&input, options()).unwrap()),
            ["2026-10-30T10:00"]
        );
        let narrow = ParseOptions {
            range: Some((utc("2026-10-01T00:00"), utc("2026-10-15T00:00"))),
            ..options()
        };
        assert!(parse(&input, narrow).unwrap().is_empty());
        expect_starts(
            "DTSTART:20260925T100000Z\nRRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3",
            &["2026-10-30T10:00", "2026-11-27T10:00"],
        );
    }

    #[test]
    fn daily_weekly_hourly_and_minutely_expansion_preserve_the_interval() {
        expect_starts(
            "DTSTART:20261019T100000Z\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=MO;COUNT=4",
            &[
                "2026-10-19T10:00",
                "2026-10-21T10:00",
                "2026-11-02T10:00",
                "2026-11-04T10:00",
            ],
        );
        expect_starts(
            "DTSTART:20261021T170000Z\nRRULE:FREQ=DAILY;COUNT=3;BYHOUR=9,17;BYSETPOS=-1",
            &["2026-10-21T17:00", "2026-10-22T17:00", "2026-10-23T17:00"],
        );
        expect_starts(
            "DTSTART:20261021T100500Z\nRRULE:FREQ=HOURLY;INTERVAL=2;COUNT=4;BYMINUTE=5,25",
            &[
                "2026-10-21T10:05",
                "2026-10-21T10:25",
                "2026-10-21T12:05",
                "2026-10-21T12:25",
            ],
        );
        expect_starts(
            "DTSTART:20261021T105500Z\nRRULE:FREQ=MINUTELY;INTERVAL=11;COUNT=3",
            &["2026-10-21T10:55", "2026-10-21T11:06", "2026-10-21T11:17"],
        );
        expect_starts(
            "DTSTART;TZID=Europe/Paris:20261025T011500\nRRULE:FREQ=HOURLY;COUNT=4",
            &[
                "2026-10-24T23:15",
                "2026-10-25T00:15",
                "2026-10-25T01:15",
                "2026-10-25T02:15",
            ],
        );
    }

    #[test]
    fn yearly_leap_days_are_skipped_in_ordinary_years() {
        let input = event("DTSTART:20240229T100000Z\nRRULE:FREQ=YEARLY;COUNT=3");
        let wider = ParseOptions {
            range: Some((utc("2025-01-01T00:00"), utc("2033-01-01T00:00"))),
            ..options()
        };
        assert_eq!(
            starts(&parse(&input, wider).unwrap()),
            ["2028-02-29T10:00", "2032-02-29T10:00"]
        );
    }

    #[test]
    fn exclusions_and_overrides_keep_existing_series_identity() {
        let input = [
            event("DTSTART:20261021T100000Z\nDURATION:PT30M\nRRULE:FREQ=DAILY;COUNT=4\nEXDATE:20261022T100000Z\nRDATE:20261025T100000Z\nDESCRIPTION:План"),
            event("RECURRENCE-ID;RANGE=THISANDFUTURE:20261023T100000Z\nDTSTART:20261023T110000Z\nSUMMARY:Перенос"),
            event("RECURRENCE-ID:20261024T100000Z\nSTATUS:CANCELLED"),
        ].join("\n");
        let options = ParseOptions {
            account_login: "one@example.test",
            ..options()
        };
        let meetings = parse(&input, options).unwrap();
        assert_eq!(
            starts(&meetings),
            [
                "2026-10-21T10:00",
                "2026-10-23T11:00",
                "2026-10-24T10:00",
                "2026-10-25T11:00"
            ]
        );
        assert_eq!(meetings[1].original_start, Some(utc("2026-10-23T10:00")));
        assert_eq!(
            meetings[1].id,
            "account:b25lQGV4YW1wbGUudGVzdA==:work|series|1792749600.0"
        );
        assert_eq!(meetings[1].details, "План");
        assert_eq!(meetings[1].end - meetings[1].start, 30 * MINUTE);
        assert!(meetings[2].cancelled);
        let encoded = serde_json::to_value(&meetings[1]).unwrap();
        assert_eq!(
            encoded["calendarID"],
            "account:b25lQGV4YW1wbGUudGVzdA==:work"
        );
        assert_eq!(
            encoded["seriesID"],
            "account:b25lQGV4YW1wbGUudGVzdA==:work|series"
        );
        assert_eq!(
            serde_json::from_value::<Meeting>(encoded).unwrap(),
            meetings[1]
        );
    }

    #[test]
    fn timezone_preserves_local_recurrence_time_and_all_day_dates() {
        expect_starts(
            "DTSTART;TZID=Europe/Paris:20261024T090000\nRRULE:FREQ=DAILY;COUNT=3",
            &["2026-10-24T07:00", "2026-10-25T08:00", "2026-10-26T08:00"],
        );
        let input = event("DTSTART;VALUE=DATE:20261024\nRRULE:FREQ=DAILY;COUNT=3");
        let options = ParseOptions {
            fallback_zone: chrono_tz::Europe::Paris,
            ..options()
        };
        let physical = parse(&input, options).unwrap();
        assert_eq!(physical[1].end - physical[1].start, 25 * HOUR);
        let visible = parse(
            &input,
            ParseOptions {
                range: Some((utc("2026-10-25T07:00"), utc("2026-10-26T07:00"))),
                display_zone: Some(chrono_tz::America::Los_Angeles),
                ..options
            },
        )
        .unwrap();
        assert_eq!(starts(&visible), ["2026-10-25T07:00"]);
        assert_eq!(
            visible[0].all_day_dates,
            Some(AllDayDates {
                start: "2026-10-25".into(),
                end: "2026-10-26".into()
            })
        );
    }

    #[test]
    fn nominal_durations_and_series_shifts_handle_the_skipped_clock_hour() {
        let input = [
            event("DTSTART;TZID=Europe/Paris:20260328T023000\nRRULE:FREQ=DAILY;COUNT=3\nDURATION:P1D"),
            event("RECURRENCE-ID;TZID=Europe/Paris;RANGE=THISANDFUTURE:20260328T023000\nDTSTART;TZID=Europe/Paris:20260329T033000"),
        ].join("\n");
        let options = ParseOptions {
            range: Some((utc("2026-03-28T00:00"), utc("2026-04-03T00:00"))),
            ..options()
        };
        let shifted = parse(&input, options).unwrap();
        assert_eq!(
            starts(&shifted),
            ["2026-03-29T01:30", "2026-03-31T00:30", "2026-04-01T00:30"]
        );
        let unshifted = parse(
            &event("DTSTART;TZID=Europe/Paris:20260328T023000\nDURATION:P1D"),
            options,
        )
        .unwrap();
        assert_eq!(unshifted[0].end, utc("2026-03-29T01:30"));
    }

    #[test]
    fn calendar_page_and_join_urls_are_distinct() {
        let source = "https://calendar.yandex.ru/event?event_id=123";
        let link = "https://telemost.yandex.ru/j/123456";
        let input = event(&format!(
            "DTSTART:20261021T100000Z\nATTENDEE;CN=\"Иван: менеджер\";PARTSTAT=ACCEPTED:mailto:test@example.test\nDESCRIPTION:План\\nhttps://telemost.yandex.ru/j/123\n 456\nURL:{source}\nBEGIN:VALARM\nDESCRIPTION:Не описание встречи\nEND:VALARM"
        ));
        let meeting = parse(&input, options()).unwrap().pop().unwrap();
        assert_eq!(meeting.source_url.as_deref(), Some(source));
        assert_eq!(meeting.link.as_deref(), Some(link));
        assert_eq!(meeting.attendees[0].name, "Иван: менеджер");
        assert_eq!(invitation_status(&meeting, "test@example.test"), "accepted");
        assert_eq!(
            conference_url(&[source], &["https://example.test/specification"]),
            None
        );
        assert_eq!(
            telemost_desktop_url(link).as_deref(),
            Some("telemost://https://telemost.yandex.ru/j/123456")
        );
        assert_eq!(
            telemost_desktop_url("https://telemost.yandex.ru:443/j/123456"),
            None
        );
        assert_eq!(
            telemost_desktop_url("https://@telemost.yandex.ru/j/123456"),
            None
        );
        assert_eq!(
            browser_url(&format!("{link}?skip_app=0&other=1")),
            format!("{link}?skip_app=1&other=1")
        );
        assert_eq!(yandex_edit_url(&meeting, chrono_tz::UTC).unwrap(), source);
        let create = Url::parse(
            &yandex_create_url(utc("2026-10-22T23:30"), None, chrono_tz::Europe::Moscow).unwrap(),
        )
        .unwrap();
        assert!(create
            .query_pairs()
            .any(|(key, value)| key == "start" && value == "2026-10-23T02:30:00"));
        assert!(create
            .query_pairs()
            .any(|(key, value)| key == "end" && value == "2026-10-23T03:00:00"));
    }

    #[test]
    fn unsupported_or_malformed_events_are_rejected() {
        for (properties, message) in [
            ("DTSTART:20260230T100000Z", "начало встречи"),
            ("DTSTART;TZID=Not/Known:20261021T100000", "часовой пояс"),
            (
                "DTSTART:20261021T100000Z\nRRULE:FREQ=DAILY;X-UNKNOWN=1",
                "X-UNKNOWN",
            ),
        ] {
            assert!(parse(&event(properties), options())
                .unwrap_err()
                .contains(message));
        }
    }
}
