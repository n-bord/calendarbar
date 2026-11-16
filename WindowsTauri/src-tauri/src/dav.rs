use crate::calendar::{parse_icalendar, scoped_id, Meeting, ParseOptions};
use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{DateTime, Utc};
use chrono_tz::Tz;
#[cfg(test)]
use reqwest::Request;
use reqwest::{
    header::{HeaderValue, AUTHORIZATION, CACHE_CONTROL, CONTENT_TYPE, ETAG},
    redirect::Policy,
    Client, Method,
};
use roxmltree::{Document, Node, ParsingOptions};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    sync::LazyLock,
    time::Duration,
};
use url::Url;

const DAV: &str = "DAV:";
const CALDAV: &str = "urn:ietf:params:xml:ns:caldav";
const NAMESPACES: &str = "xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\"";
const AUTH_ERROR: &str = "Нет доступа к календарю. Проверьте полный рабочий e-mail, пароль приложения типа «Календарь» и ограничения организации.";
const CONNECTION_ERROR: &str = "Нет ответа от Яндекс Календаря. Проверьте подключение к интернету.";
const DATA_ERROR: &str = "Не удалось прочитать данные CalDAV. Кэш сохранён.";
const XML_ERROR: &str = "Некорректный XML-ответ CalDAV. Кэш сохранён.";
const HOST_ERROR: &str = "CalDAV вернул адрес вне доверенного сервера Яндекса.";
const RANGE_ERROR: &str = "Выберите корректный период календаря.";
const DAY: i64 = 86_400_000;

static SERVER: LazyLock<Url> =
    LazyLock::new(|| Url::parse("https://caldav.yandex.ru/").expect("Yandex CalDAV URL"));

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CalendarInfo {
    pub id: String,
    #[serde(rename = "sourceID", default)]
    pub source_id: String,
    pub name: String,
    #[serde(rename = "accountLogin", default)]
    pub account_login: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CachedResource {
    pub href: String,
    #[serde(default)]
    pub etag: Option<String>,
    pub data: String,
    #[serde(default)]
    pub last_used: i64,
}

pub type Resources = BTreeMap<String, CachedResource>;

#[derive(Debug, Default)]
pub struct CalendarBatch {
    pub meetings: Vec<Meeting>,
    pub failed_resources: BTreeMap<String, String>,
    pub resources: Resources,
    pub complete: bool,
}

#[derive(Debug)]
enum DavError {
    Report(u16),
    Resource(u16),
    Message(&'static str),
}

impl std::fmt::Display for DavError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Report(401 | 403) => f.write_str(AUTH_ERROR),
            Self::Report(status) => write!(f, "Ошибка CalDAV: HTTP {status}. Кэш встреч сохранён."),
            Self::Resource(status @ (401 | 403)) => write!(
                f,
                "Сервер запретил чтение события (HTTP {status}). Проверьте права на календарь. Кэш сохранён."
            ),
            Self::Resource(status @ (404 | 410)) => write!(
                f,
                "Не удалось прочитать событие после повторной проверки (HTTP {status}). Кэш сохранён."
            ),
            Self::Resource(status) => write!(
                f,
                "Ошибка чтения события CalDAV: HTTP {status}. Кэш сохранён."
            ),
            Self::Message(message) => f.write_str(message),
        }
    }
}

impl DavError {
    fn missing_resource(&self) -> bool {
        matches!(self, Self::Resource(404 | 410))
    }

    fn unsupported(&self) -> bool {
        matches!(
            self,
            Self::Report(400 | 405 | 415 | 501) | Self::Resource(405 | 501)
        )
    }
}

type DavResult<T> = Result<T, DavError>;
type XmlNode<'a, 'input> = Node<'a, 'input>;

fn trusted_url(href: &str, base: &Url) -> DavResult<Url> {
    let url = base.join(href).map_err(|_| DavError::Message(HOST_ERROR))?;
    if url.origin() != SERVER.origin()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(DavError::Message(HOST_ERROR));
    }
    Ok(url)
}

fn multistatus(body: &str) -> DavResult<Document<'_>> {
    let options = ParsingOptions {
        allow_dtd: false,
        ..ParsingOptions::default()
    };
    let xml =
        Document::parse_with_options(body, options).map_err(|_| DavError::Message(XML_ERROR))?;
    if !xml.root_element().has_tag_name((DAV, "multistatus")) {
        return Err(DavError::Message(XML_ERROR));
    }
    Ok(xml)
}

fn child<'a, 'input>(
    node: XmlNode<'a, 'input>,
    namespace: &str,
    name: &str,
) -> Option<XmlNode<'a, 'input>> {
    node.children()
        .find(|child| child.has_tag_name((namespace, name)))
}

fn text(node: XmlNode<'_, '_>) -> String {
    node.children()
        .filter(|child| child.is_text())
        .filter_map(|child| child.text())
        .collect()
}

fn nonempty(node: Option<XmlNode<'_, '_>>) -> Option<String> {
    let value = text(node?);
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn response_status(node: XmlNode<'_, '_>) -> Option<u16> {
    let value = child(node, DAV, "status")?;
    let text = text(value);
    let mut words = text.split_whitespace();
    let protocol = words.next()?.strip_prefix("HTTP/")?;
    let code = words.next()?;
    if protocol.is_empty() || code.len() != 3 || !code.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    code.parse()
        .ok()
        .filter(|status| (100..600).contains(status))
}

fn properties<'a, 'input>(
    response: XmlNode<'a, 'input>,
) -> impl Iterator<Item = XmlNode<'a, 'input>> {
    response
        .children()
        .filter(|node| node.has_tag_name((DAV, "propstat")) && response_status(*node) == Some(200))
        .filter_map(|node| child(node, DAV, "prop"))
}

fn responses<'a, 'input>(
    document: &'a Document<'input>,
) -> impl Iterator<Item = XmlNode<'a, 'input>> {
    document
        .root_element()
        .children()
        .filter(|node| node.has_tag_name((DAV, "response")))
}

#[derive(Debug)]
struct Reference {
    href: String,
    etag: Option<String>,
    data: Option<String>,
}

fn read_reference(response: XmlNode<'_, '_>, base: &Url) -> DavResult<Reference> {
    if child(response, DAV, "status").is_some() {
        let status = response_status(response).ok_or(DavError::Message(
            "Некорректный статус ответа CalDAV. Кэш сохранён.",
        ))?;
        if status != 200 {
            return Err(DavError::Resource(status));
        }
    }
    let href = nonempty(child(response, DAV, "href"))
        .ok_or(DavError::Message("В ответе CalDAV нет адреса события."))?;
    let href = trusted_url(&href, base)?.into();
    let props: Vec<_> = properties(response).collect();
    if props.is_empty() {
        let stats: Vec<_> = response
            .children()
            .filter(|node| node.has_tag_name((DAV, "propstat")))
            .collect();
        let only_missing_etag = !stats.is_empty()
            && stats.iter().all(|node| {
                response_status(*node) == Some(404)
                    && child(*node, DAV, "prop").is_some_and(|property| {
                        let mut values = property
                            .children()
                            .filter(|item| item.is_element())
                            .peekable();
                        values.peek().is_some()
                            && values.all(|value| value.has_tag_name((DAV, "getetag")))
                    })
            });
        if !only_missing_etag {
            let status = stats
                .iter()
                .find_map(|node| response_status(*node))
                .unwrap_or(500);
            return Err(DavError::Resource(status));
        }
    }
    let etag = nonempty(props.iter().find_map(|prop| child(*prop, DAV, "getetag")));
    let data = props
        .iter()
        .find_map(|prop| child(*prop, CALDAV, "calendar-data"))
        .map(text);
    Ok(Reference { href, etag, data })
}

fn stamp(time: i64) -> DavResult<String> {
    DateTime::<Utc>::from_timestamp_millis(time)
        .map(|date| date.format("%Y%m%dT%H%M%SZ").to_string())
        .ok_or(DavError::Message(RANGE_ERROR))
}

fn query_body(from: i64, to: i64, full: bool) -> DavResult<String> {
    let data = if full { "<c:calendar-data/>" } else { "" };
    let from = stamp(from)?;
    let to = stamp(to)?;
    Ok(format!(
        r#"<c:calendar-query {NAMESPACES}><d:prop><d:getetag/>{data}</d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range start="{from}" end="{to}"/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"#
    ))
}

fn escape_xml(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

pub struct YandexCalendarClient {
    login: String,
    client: Client,
    authorization: HeaderValue,
    #[cfg(test)]
    mock: Option<Box<dyn Fn(Request) -> MockReply + Send + Sync>>,
}

#[cfg(test)]
struct MockReply {
    status: u16,
    body: String,
}

impl YandexCalendarClient {
    pub fn new(login: &str, password: &str) -> Result<Self, String> {
        let client = Client::builder()
            .https_only(true)
            .redirect(Policy::none())
            .timeout(Duration::from_secs(60))
            .build()
            .map_err(|_| CONNECTION_ERROR.to_owned())?;
        let mut authorization = HeaderValue::from_str(&format!(
            "Basic {}",
            STANDARD.encode(format!("{login}:{password}"))
        ))
        .map_err(|_| AUTH_ERROR.to_owned())?;
        authorization.set_sensitive(true);
        Ok(Self {
            login: login.to_owned(),
            client,
            authorization,
            #[cfg(test)]
            mock: None,
        })
    }

    async fn request(
        &self,
        url: &Url,
        method: Method,
        query: Option<(&str, String)>,
    ) -> DavResult<(String, Option<String>)> {
        let target = trusted_url(url.as_ref(), &SERVER)?;
        let download = method == Method::GET;
        let mut builder = self
            .client
            .request(method, target)
            .header(AUTHORIZATION, self.authorization.clone())
            .header(CACHE_CONTROL, "no-store");
        if let Some((depth, body)) = query {
            builder = builder
                .header("Depth", depth)
                .header(CONTENT_TYPE, "application/xml; charset=utf-8")
                .body(body);
        }
        let request = builder.build().map_err(|_| DavError::Message(DATA_ERROR))?;
        #[cfg(test)]
        if let Some(mock) = &self.mock {
            let reply = mock(request);
            Self::validate_status(reply.status, download)?;
            return Ok((reply.body, None));
        }
        let response = self
            .client
            .execute(request)
            .await
            .map_err(|_| DavError::Message(CONNECTION_ERROR))?;
        Self::validate_status(response.status().as_u16(), download)?;
        let etag = response
            .headers()
            .get(ETAG)
            .and_then(|header| header.to_str().ok())
            .map(str::to_owned);
        let bytes = response
            .bytes()
            .await
            .map_err(|_| DavError::Message(DATA_ERROR))?;
        let body = std::str::from_utf8(&bytes).map_err(|_| DavError::Message(DATA_ERROR))?;
        Ok((
            body.strip_prefix('\u{feff}').unwrap_or(body).to_owned(),
            etag,
        ))
    }

    fn validate_status(status: u16, download: bool) -> DavResult<()> {
        match (status, download) {
            (200, true) | (207, false) => Ok(()),
            (_, true) => Err(DavError::Resource(status)),
            (_, false) => Err(DavError::Report(status)),
        }
    }

    async fn propfind(&self, url: &Url, depth: &str, names: &str) -> DavResult<String> {
        let method = Method::from_bytes(b"PROPFIND").expect("CalDAV method");
        let body = format!("<d:propfind {NAMESPACES}><d:prop>{names}</d:prop></d:propfind>");
        self.request(url, method, Some((depth, body)))
            .await
            .map(|(body, _)| body)
    }

    async fn discover(&self) -> DavResult<Vec<CalendarInfo>> {
        let body = self
            .propfind(&SERVER, "0", "<d:current-user-principal/>")
            .await?;
        let document = multistatus(&body)?;
        let principal = responses(&document)
            .flat_map(properties)
            .filter_map(|prop| child(prop, DAV, "current-user-principal"))
            .find_map(|node| nonempty(child(node, DAV, "href")))
            .ok_or(DavError::Message("CalDAV не сообщил адрес пользователя."))?;
        let principal = trusted_url(&principal, &SERVER)?;
        let body = self
            .propfind(&principal, "0", "<c:calendar-home-set/>")
            .await?;
        let document = multistatus(&body)?;
        let homes: Vec<_> = responses(&document)
            .flat_map(properties)
            .filter_map(|prop| child(prop, CALDAV, "calendar-home-set"))
            .flat_map(|node| {
                node.children()
                    .filter(|item| item.has_tag_name((DAV, "href")))
            })
            .filter_map(|node| nonempty(Some(node)))
            .map(|href| trusted_url(&href, &principal))
            .collect::<DavResult<_>>()?;
        if homes.is_empty() {
            return Err(DavError::Message("CalDAV не сообщил адрес календарей."));
        }
        let mut calendars = BTreeMap::new();
        for home in homes {
            let body = self
                .propfind(&home, "1", "<d:resourcetype/><d:displayname/>")
                .await?;
            let document = multistatus(&body)?;
            for response in responses(&document) {
                let props: Vec<_> = properties(response).collect();
                if !props.iter().any(|prop| {
                    child(*prop, DAV, "resourcetype")
                        .and_then(|node| child(node, CALDAV, "calendar"))
                        .is_some()
                }) {
                    continue;
                }
                let Some(href) = nonempty(child(response, DAV, "href")) else {
                    continue;
                };
                let source_id = trusted_url(&href, &home)?.to_string();
                let id = scoped_id(&source_id, &self.login);
                let name = props
                    .into_iter()
                    .find_map(|prop| nonempty(child(prop, DAV, "displayname")))
                    .unwrap_or_else(|| "Календарь".to_owned());
                calendars.entry(id.clone()).or_insert(CalendarInfo {
                    id,
                    source_id,
                    name,
                    account_login: self.login.clone(),
                });
            }
        }
        if calendars.is_empty() {
            return Err(DavError::Message("Доступные календари не найдены."));
        }
        let mut calendars: Vec<_> = calendars.into_values().collect();
        calendars.sort_by_cached_key(|calendar| calendar.name.to_lowercase().replace('ё', "е"));
        Ok(calendars)
    }

    pub async fn calendars(&self) -> Result<Vec<CalendarInfo>, String> {
        self.discover().await.map_err(|error| error.to_string())
    }

    async fn report(&self, url: &Url, body: String) -> DavResult<Vec<Reference>> {
        let method = Method::from_bytes(b"REPORT").expect("CalDAV method");
        let (body, _) = self.request(url, method, Some(("1", body))).await?;
        let document = multistatus(&body)?;
        responses(&document)
            .map(|response| read_reference(response, url))
            .collect()
    }

    async fn download(&self, reference: Reference) -> DavResult<CachedResource> {
        let url = trusted_url(&reference.href, &SERVER)?;
        let (data, etag) = self.request(&url, Method::GET, None).await?;
        Ok(CachedResource {
            href: reference.href,
            etag: etag.or(reference.etag),
            data,
            last_used: Utc::now().timestamp_millis(),
        })
    }

    async fn fetch_batch(
        &self,
        url: &Url,
        references: Vec<Reference>,
    ) -> DavResult<Vec<CachedResource>> {
        let mut hrefs = String::new();
        for reference in &references {
            let target = trusted_url(&reference.href, url)?;
            let path_with_query = match target.query() {
                Some(query) => format!("{}?{query}", target.path()),
                None => target.path().to_owned(),
            };
            hrefs.push_str("<d:href>");
            hrefs.push_str(&escape_xml(&path_with_query));
            hrefs.push_str("</d:href>");
        }
        let body = format!(
            "<c:calendar-multiget {NAMESPACES}><d:prop><d:getetag/><c:calendar-data/></d:prop>{hrefs}</c:calendar-multiget>"
        );
        let returned = match self.report(url, body).await {
            Ok(results) => results,
            Err(error) if error.unsupported() || error.missing_resource() => Vec::new(),
            Err(error) => return Err(error),
        };
        let requested: BTreeSet<&str> = references.iter().map(|item| item.href.as_str()).collect();
        let mut bodies = HashMap::new();
        for reference in returned {
            if !requested.contains(reference.href.as_str()) {
                return Err(DavError::Message(
                    "Сервер вернул незапрошенное событие. Сохранённые встречи не изменены.",
                ));
            }
            if let Some(data) = reference.data {
                bodies.insert(reference.href, (data, reference.etag));
            }
        }
        let mut downloaded = Vec::with_capacity(references.len());
        for reference in references {
            let resource = if let Some((data, etag)) = bodies.remove(&reference.href) {
                CachedResource {
                    href: reference.href,
                    etag: etag.or(reference.etag),
                    data,
                    last_used: Utc::now().timestamp_millis(),
                }
            } else {
                self.download(reference).await?
            };
            downloaded.push(resource);
        }
        Ok(downloaded)
    }

    async fn fetch_changes(
        &self,
        url: &Url,
        from: i64,
        to: i64,
        cached: &Resources,
    ) -> DavResult<Vec<CachedResource>> {
        let references = self.report(url, query_body(from, to, false)?).await?;
        let mut resources = Vec::with_capacity(references.len());
        let mut changed = Vec::new();
        for reference in references {
            if let Some(old) = cached
                .get(&reference.href)
                .filter(|old| reference.etag.is_some() && old.etag == reference.etag)
            {
                let mut resource = old.clone();
                resource.href = reference.href;
                resource.last_used = Utc::now().timestamp_millis();
                resources.push(resource);
            } else {
                changed.push(reference);
            }
        }
        let mut changed = changed.into_iter();
        loop {
            let batch: Vec<_> = changed.by_ref().take(40).collect();
            if batch.is_empty() {
                break;
            }
            resources.extend(self.fetch_batch(url, batch).await?);
        }
        Ok(resources)
    }

    async fn fetch_resources(
        &self,
        url: &Url,
        from: i64,
        to: i64,
        cached: &Resources,
    ) -> DavResult<Vec<CachedResource>> {
        match self.fetch_changes(url, from, to, cached).await {
            Ok(resources) => return Ok(resources),
            // An event may have disappeared between REPORT and GET. Re-list once.
            Err(error) if error.missing_resource() => {
                match self.fetch_changes(url, from, to, cached).await {
                    Ok(resources) => return Ok(resources),
                    Err(error) if error.missing_resource() || error.unsupported() => {}
                    Err(error) => return Err(error),
                }
            }
            Err(error) if error.unsupported() => {}
            Err(error) => return Err(error),
        }
        self.report(url, query_body(from, to, true)?)
            .await?
            .into_iter()
            .map(|reference| {
                let data = reference.data.ok_or(DavError::Message(
                    "Сервер не вернул полные данные календаря. Кэш сохранён.",
                ))?;
                Ok(CachedResource {
                    href: reference.href,
                    etag: reference.etag,
                    data,
                    last_used: Utc::now().timestamp_millis(),
                })
            })
            .collect()
    }

    pub async fn meetings(
        &self,
        calendar: &CalendarInfo,
        from: i64,
        to: i64,
        cached: &Resources,
        fallback_zone: Tz,
        display_zone: Tz,
    ) -> Result<CalendarBatch, String> {
        if !calendar.account_login.is_empty()
            && calendar.account_login.to_lowercase() != self.login.to_lowercase()
        {
            return Err("Календарь относится к другому аккаунту.".to_owned());
        }
        if from >= to {
            return Err(RANGE_ERROR.to_owned());
        }
        let href = if calendar.source_id.is_empty() {
            &calendar.id
        } else {
            &calendar.source_id
        };
        let url = trusted_url(href, &SERVER).map_err(|error| error.to_string())?;
        // DATE values may straddle a UTC query boundary when the zones differ.
        let padding = if display_zone == fallback_zone {
            0
        } else {
            2 * DAY
        };
        let downloaded = self
            .fetch_resources(
                &url,
                from.saturating_sub(padding),
                to.saturating_add(padding),
                cached,
            )
            .await
            .map_err(|error| error.to_string())?;
        let mut batch = CalendarBatch::default();
        for resource in downloaded {
            let options = ParseOptions {
                calendar_id: url.as_ref(),
                calendar_name: &calendar.name,
                account_login: &self.login,
                fallback_zone,
                display_zone: Some(display_zone),
                resource_url: Some(&resource.href),
                etag: resource.etag.as_deref(),
                range: Some((from, to)),
            };
            match parse_icalendar(&resource.data, options) {
                Ok(events) => {
                    batch.meetings.extend(events);
                    batch.resources.insert(resource.href.clone(), resource);
                }
                Err(error) => {
                    batch.failed_resources.insert(resource.href, error);
                }
            }
        }
        batch.complete = batch.failed_resources.is_empty();
        Ok(batch)
    }
}

pub fn merge_calendar_meetings(previous: Vec<Meeting>, result: &mut CalendarBatch) -> Vec<Meeting> {
    let mut meetings = std::mem::take(&mut result.meetings);
    if result.complete {
        return meetings;
    }
    let mut ids: BTreeSet<_> = meetings.iter().map(|event| event.id.clone()).collect();
    for event in previous {
        let retained = event
            .resource_url
            .as_ref()
            .is_none_or(|url| result.failed_resources.contains_key(url));
        if retained && ids.insert(event.id.clone()) {
            meetings.push(event);
        }
    }
    meetings
}

pub fn prune_calendar_resources(resources: Resources) -> Resources {
    let mut resources: Vec<_> = resources.into_values().collect();
    resources.sort_by_cached_key(|resource| std::cmp::Reverse(resource.last_used));
    let mut remaining: usize = 24 * 1024 * 1024;
    resources
        .into_iter()
        .take(3000)
        .take_while(|resource| {
            if let Some(bytes) = remaining.checked_sub(resource.data.len()) {
                remaining = bytes;
                true
            } else {
                false
            }
        })
        .map(|resource| (resource.href.clone(), resource))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        collections::VecDeque,
        sync::{Arc, Mutex},
    };

    const LOGIN: &str = "me@example.org";
    const CALENDAR: &str = "https://caldav.yandex.ru/accounts/Me/Work/";
    const FROM: i64 = 1_792_627_200_000;
    const TO: i64 = 1_792_972_800_000;

    struct Exchange {
        method: &'static str,
        path: &'static str,
        has: &'static str,
        has_not: &'static str,
        reply: MockReply,
    }

    fn client(replies: Vec<Exchange>) -> (YandexCalendarClient, Arc<Mutex<VecDeque<Exchange>>>) {
        let mut client = YandexCalendarClient::new(LOGIN, "test-only").unwrap();
        let remaining = Arc::new(Mutex::new(VecDeque::from(replies)));
        let requests = remaining.clone();
        client.mock = Some(Box::new(move |request| {
            let exchange = requests
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected request");
            let body = request
                .body()
                .and_then(|body| body.as_bytes())
                .unwrap_or_default();
            let body = std::str::from_utf8(body).unwrap();
            assert_eq!(request.url().host_str(), Some("caldav.yandex.ru"));
            assert_eq!(request.url().path(), exchange.path);
            assert_eq!(request.method().as_str(), exchange.method);
            assert_eq!(
                request.headers()["authorization"],
                "Basic bWVAZXhhbXBsZS5vcmc6dGVzdC1vbmx5"
            );
            assert!(request.headers()["authorization"].is_sensitive());
            assert!(body.contains(exchange.has), "{body}");
            if !exchange.has_not.is_empty() {
                assert!(!body.contains(exchange.has_not), "{body}");
            }
            exchange.reply
        }));
        (client, remaining)
    }

    fn status(status: u16) -> MockReply {
        MockReply {
            status,
            body: String::new(),
        }
    }

    fn xml(content: &str) -> MockReply {
        MockReply {
            status: 207,
            body: format!(
                r#"<multistatus xmlns="DAV:" xmlns:x="urn:ietf:params:xml:ns:caldav">{content}</multistatus>"#
            ),
        }
    }

    fn entry(href: &str, props: &str) -> String {
        format!("<response><href>{href}</href><propstat><prop>{props}</prop><status>HTTP/1.1 200 OK</status></propstat></response>")
    }

    fn event(uid: &str) -> String {
        format!("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:{uid}\r\nSUMMARY:Встреча\r\nDTSTART:20261023T100000Z\r\nDTEND:20261023T110000Z\r\nEND:VEVENT\r\nEND:VCALENDAR")
    }

    fn event_entry(uid: &str, etag: &str, data: Option<&str>) -> String {
        let data = data
            .map(|body| format!("<x:calendar-data><![CDATA[{body}]]></x:calendar-data>"))
            .unwrap_or_default();
        entry(
            &format!("{CALENDAR}{uid}.ics"),
            &format!("<getetag>{etag}</getetag>{data}"),
        )
    }

    fn calendar() -> CalendarInfo {
        CalendarInfo {
            id: scoped_id(CALENDAR, LOGIN),
            source_id: CALENDAR.into(),
            name: "Рабочий".into(),
            account_login: LOGIN.into(),
        }
    }

    async fn sync(
        client: &YandexCalendarClient,
        cache: &Resources,
    ) -> Result<CalendarBatch, String> {
        client
            .meetings(
                &calendar(),
                FROM,
                TO,
                cache,
                chrono_tz::Europe::Moscow,
                chrono_tz::Europe::Moscow,
            )
            .await
    }

    fn report(has: &'static str, has_not: &'static str, reply: MockReply) -> Exchange {
        Exchange {
            method: "REPORT",
            path: "/accounts/Me/Work/",
            has,
            has_not,
            reply,
        }
    }

    #[tokio::test]
    async fn finds_namespaced_calendars_and_keeps_case_sensitive_paths() {
        let replies = vec![
            Exchange { method: "PROPFIND", path: "/", has: "current-user-principal", has_not: "", reply: xml(&entry("/", "<current-user-principal><href>/accounts/Me/</href></current-user-principal>")) },
            Exchange { method: "PROPFIND", path: "/accounts/Me/", has: "calendar-home-set", has_not: "", reply: xml(&entry("/accounts/Me/", "<x:calendar-home-set><href>/accounts/Me/Calendars/</href></x:calendar-home-set>")) },
            Exchange { method: "PROPFIND", path: "/accounts/Me/Calendars/", has: "displayname", has_not: "", reply: xml(&entry(CALENDAR, "<resourcetype><x:calendar/></resourcetype><displayname>Ревью &amp; встречи</displayname>")) },
        ];
        let (client, remaining) = client(replies);
        let calendars = client.calendars().await.unwrap();
        assert!(remaining.lock().unwrap().is_empty());
        assert_eq!(calendars.len(), 1);
        assert_eq!(calendars[0].id, calendar().id);
        assert_eq!(calendars[0].source_id, CALENDAR);
        assert_eq!(calendars[0].name, "Ревью & встречи");
    }

    #[tokio::test]
    async fn refuses_redirects_foreign_hrefs_and_wrong_xml_namespace() {
        for (reply, expected) in [
            (status(302), "HTTP 302"),
            (xml(&entry("/", "<current-user-principal><href>https://example.test/p/</href></current-user-principal>")), HOST_ERROR),
            (MockReply { status: 207, body: "<multistatus xmlns=\"http://example.test/\"/>".into() }, XML_ERROR),
        ] {
            let (client, left) = client(vec![Exchange { method: "PROPFIND", path: "/", has: "", has_not: "", reply }]);
            assert!(client.calendars().await.unwrap_err().contains(expected));
            assert!(left.lock().unwrap().is_empty());
        }
    }

    #[test]
    fn refuses_dtd_and_only_accepts_the_expected_origin() {
        assert!(multistatus(
            r#"<!DOCTYPE multistatus [<!ENTITY a "b">]><multistatus xmlns="DAV:">&a;</multistatus>"#
        )
        .is_err());
        assert!(trusted_url("https://caldav.yandex.ru:444/", &SERVER).is_err());
        assert!(trusted_url("https://other@caldav.yandex.ru/", &SERVER).is_err());
        assert!(trusted_url("http://caldav.yandex.ru/", &SERVER).is_err());
    }

    #[tokio::test]
    async fn reuses_etags_and_keeps_failed_cached_events_only() {
        let href = |name| format!("{CALENDAR}{name}.ics");
        let mut cache = Resources::new();
        for uid in ["same", "changed", "gone"] {
            cache.insert(
                href(uid),
                CachedResource {
                    href: href(uid),
                    etag: Some("\"1\"".into()),
                    data: event(uid),
                    last_used: 0,
                },
            );
        }
        let old = ["changed", "gone"]
            .into_iter()
            .flat_map(|uid| {
                parse_icalendar(
                    &event(uid),
                    ParseOptions {
                        calendar_id: CALENDAR,
                        calendar_name: "Рабочий",
                        account_login: LOGIN,
                        fallback_zone: chrono_tz::Europe::Moscow,
                        display_zone: None,
                        resource_url: Some(&href(uid)),
                        etag: Some("\"1\""),
                        range: Some((FROM, TO)),
                    },
                )
                .unwrap()
            })
            .collect();
        let (client, left) = client(vec![
            report(
                "calendar-query",
                "calendar-data",
                xml(&(event_entry("same", "\"1\"", None) + &event_entry("changed", "\"2\"", None))),
            ),
            report(
                "<d:href>/accounts/Me/Work/changed.ics</d:href>",
                "same.ics",
                xml(&event_entry("changed", "\"2\"", Some("BAD CALENDAR"))),
            ),
        ]);
        let mut result = sync(&client, &cache).await.unwrap();
        assert!(left.lock().unwrap().is_empty());
        assert!(!result.complete);
        assert!(result.resources.contains_key(&href("same")));
        assert!(result.failed_resources.contains_key(&href("changed")));
        let retained: BTreeSet<_> = merge_calendar_meetings(old, &mut result)
            .into_iter()
            .map(|meeting| meeting.resource_url.unwrap())
            .collect();
        assert_eq!(retained, BTreeSet::from([href("same"), href("changed")]));
    }

    #[tokio::test]
    async fn relists_once_after_resource_disappears_between_requests() {
        let (client, left) = client(vec![
            report("calendar-query", "calendar-data", xml(&event_entry("gone", "\"1\"", None))),
            report("calendar-multiget", "", xml(&format!("<response><href>{CALENDAR}gone.ics</href><status>HTTP/1.1 404</status></response>"))),
            Exchange { method: "GET", path: "/accounts/Me/Work/gone.ics", has: "", has_not: "", reply: status(404) },
            report("calendar-query", "calendar-data", xml("")),
        ]);
        let result = sync(&client, &Resources::new()).await.unwrap();
        assert!(left.lock().unwrap().is_empty());
        assert!(result.complete);
        assert!(result.meetings.is_empty());
    }

    #[tokio::test]
    async fn falls_back_to_full_query_when_metadata_report_is_unsupported() {
        let (client, left) = client(vec![
            report("calendar-query", "calendar-data", status(405)),
            report(
                "<c:calendar-data/>",
                "",
                xml(&event_entry("all", "\"1\"", Some(&event("all")))),
            ),
        ]);
        let result = sync(&client, &Resources::new()).await.unwrap();
        assert!(left.lock().unwrap().is_empty());
        assert!(result.complete);
        assert_eq!(result.meetings.len(), 1);
    }
}
