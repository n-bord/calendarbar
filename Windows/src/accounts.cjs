'use strict';

const sax = require('sax');
const { parseICalendar, scopedID, isYandexEventURL, yandexCreateURL, yandexEditURL } = require('./calendar.cjs');

const DAV = 'DAV:';
const CALDAV = 'urn:ietf:params:xml:ns:caldav';
const SERVER = new URL('https://caldav.yandex.ru/');
const DAV_NAMESPACES = `xmlns:d="${DAV}" xmlns:c="${CALDAV}"`;
const UNSUPPORTED_REPORT = [400, 405, 415, 501];
const MISSING_RESOURCE = [404, 410];
const UNSUPPORTED_GET = [405, 501];
const DAY = 24 * 60 * 60 * 1000;

class CalDAVHttpError extends Error {
  constructor(status) {
    super(`Ошибка CalDAV: HTTP ${status}. Кэш встреч сохранён.`);
    this.status = status;
  }
}

class CalDAVResourceError extends Error {
  constructor(status) {
    let description = `Ошибка чтения события CalDAV: HTTP ${status}.`;
    if (status === 401 || status === 403) {
      description = `Сервер запретил чтение события (HTTP ${status}). Проверьте права на календарь.`;
    }
    if (MISSING_RESOURCE.includes(status)) {
      description = `Не удалось прочитать событие после повторной проверки (HTTP ${status}).`;
    }
    super(description + ' Кэш сохранён.');
    this.status = status;
  }
}

function trustedURL(href, base = SERVER) {
  try {
    const url = new URL(href, base);
    if (url.protocol === 'https:' && url.origin === SERVER.origin && !url.username && !url.password && !url.hash) {
      return url;
    }
  } catch {
    // The same trust rule applies when the server returns an invalid URL.
  }
  throw new Error('CalDAV вернул адрес вне доверенного сервера Яндекса.');
}

function parseMultistatus(body) {
  const stack = [];
  const parser = sax.parser(true, { xmlns: true, strictEntities: true });
  let root;
  const invalid = () => new Error('Некорректный XML-ответ CalDAV.');
  parser.onerror = () => { throw invalid(); };
  parser.ondoctype = () => { throw invalid(); };
  parser.onopentag = tag => {
    const node = { name: tag.local, uri: tag.uri, children: [], text: '' };
    const parent = stack.at(-1);
    if (parent) {
      parent.children.push(node);
    } else {
      if (root || node.name !== 'multistatus' || node.uri !== DAV) throw invalid();
      root = node;
    }
    stack.push(node);
  };
  parser.onclosetag = () => stack.pop();
  parser.ontext = parser.oncdata = text => {
    const node = stack.at(-1);
    if (node) node.text += text;
  };
  // Stream text to the parser in chunks so large calendar-data elements can be flushed.
  for (let offset = 0; offset < body.length; offset += 16 * 1024) {
    parser.write(body.slice(offset, offset + 16 * 1024));
  }
  parser.close();
  if (!root) throw invalid();
  return children(root, 'response');
}

function children(node, name, uri = DAV) {
  return node?.children.filter(child => child.name === name && child.uri === uri) ?? [];
}

function child(node, name, uri = DAV) {
  return children(node, name, uri)[0];
}

function readStatus(node) {
  const value = /^HTTP\/\S+\s+([1-5]\d{2})(?:\s|$)/.exec(child(node, 'status')?.text.trim() ?? '');
  return value ? Number(value[1]) : null;
}

function successfulProperties(response, properties = children(response, 'propstat')) {
  return properties.filter(prop => readStatus(prop) === 200).map(prop => child(prop, 'prop')).filter(Boolean);
}

function resourceProperties(responses, base) {
  return responses.map(response => {
    if (child(response, 'status')) {
      const status = readStatus(response);
      if (status === null) throw new Error('Некорректный статус ответа CalDAV. Кэш сохранён.');
      if (status !== 200) throw new CalDAVResourceError(status);
    }
    const href = child(response, 'href')?.text.trim();
    if (!href) throw new Error('В ответе CalDAV нет адреса события.');
    const propstats = children(response, 'propstat');
    const properties = successfulProperties(response, propstats);
    const onlyMissingETag = propstats.length > 0 && propstats.every(propstat => {
      const names = child(propstat, 'prop')?.children ?? [];
      return readStatus(propstat) === 404 && names.length > 0 &&
        names.every(property => property.name === 'getetag' && property.uri === DAV);
    });
    if (!properties.length && !onlyMissingETag) {
      throw new CalDAVResourceError(propstats.map(readStatus).find(Boolean) ?? 500);
    }
    const combined = { children: properties.flatMap(prop => prop.children) };
    return {
      href: trustedURL(href, base).href,
      etag: child(combined, 'getetag')?.text.trim() || null,
      data: child(combined, 'calendar-data', CALDAV)?.text
    };
  });
}

function escapeXML(value) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

function queryBody(from, to, includeCalendarData) {
  const stamp = value => new Date(value).toISOString().replace(/[-:]|\.\d{3}/g, '');
  return `<c:calendar-query ${DAV_NAMESPACES}>
    <d:prop><d:getetag/>${includeCalendarData ? '<c:calendar-data/>' : ''}</d:prop>
    <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
      <c:time-range start="${stamp(from)}" end="${stamp(to)}"/>
    </c:comp-filter></c:comp-filter></c:filter>
  </c:calendar-query>`;
}

function isStatus(error, type, statuses) {
  return error instanceof type && statuses.includes(error.status);
}

function localTimeZone() {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

class YandexCalendarClient {
  #login;
  #authorization;
  #fetch;
  #signal;

  constructor(login, password, { fetch = globalThis.fetch, signal } = {}) {
    this.#login = login;
    this.#authorization = 'Basic ' + Buffer.from(login + ':' + password).toString('base64');
    this.#fetch = fetch;
    this.#signal = signal;
  }

  async #request(url, method, depth, body) {
    const target = trustedURL(url);
    const headers = { Authorization: this.#authorization };
    if (body) {
      headers['Content-Type'] = 'application/xml; charset=utf-8';
      headers.Depth = depth;
    }
    const timeout = AbortSignal.timeout(60 * 1000);
    const signal = this.#signal ? AbortSignal.any([timeout, this.#signal]) : timeout;
    let response;
    try {
      response = await this.#fetch(target, { method, headers, body, redirect: 'manual', cache: 'no-store', signal });
    } catch (error) {
      this.#signal?.throwIfAborted();
      throw new Error('Нет ответа от Яндекс Календаря. Проверьте подключение к интернету.', { cause: error });
    }
    const download = method === 'GET';
    if (response.status !== (download ? 200 : 207)) {
      await response.body?.cancel().catch(() => {});
      if (download) throw new CalDAVResourceError(response.status);
      if (response.status === 401 || response.status === 403) {
        throw new Error('Нет доступа к календарю. Проверьте полный рабочий e-mail, пароль приложения типа «Календарь» и ограничения организации.');
      }
      throw new CalDAVHttpError(response.status);
    }
    const bytes = await response.arrayBuffer();
    let text;
    try {
      text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch {
      throw new Error('Не удалось прочитать данные CalDAV. Кэш сохранён.');
    }
    return { body: text, etag: response.headers.get('etag') };
  }

  async #xml(url, method, depth, body) {
    return parseMultistatus((await this.#request(url, method, depth, body)).body);
  }

  async #propfind(url, depth, names) {
    return this.#xml(url, 'PROPFIND', depth, `<d:propfind ${DAV_NAMESPACES}><d:prop>${names}</d:prop></d:propfind>`);
  }

  async calendars() {
    const found = await this.#propfind(SERVER, '0', '<d:current-user-principal/>');
    const principalHref = found.flatMap(response => successfulProperties(response))
      .map(prop => child(child(prop, 'current-user-principal'), 'href')?.text.trim())
      .find(Boolean);
    if (!principalHref) throw new Error('CalDAV не сообщил адрес пользователя.');
    const principal = trustedURL(principalHref);
    const principalProperties = await this.#propfind(principal, '0', '<c:calendar-home-set/>');
    const homes = principalProperties.flatMap(response => successfulProperties(response))
      .flatMap(prop => children(child(prop, 'calendar-home-set', CALDAV), 'href'))
      .map(node => node.text.trim()).filter(Boolean);
    if (!homes.length) throw new Error('CalDAV не сообщил адрес календарей.');

    const calendars = new Map();
    for (const href of homes) {
      const home = trustedURL(href, principal);
      const listing = await this.#propfind(home, '1', '<d:resourcetype/><d:displayname/>');
      for (const response of listing) {
        const properties = { children: successfulProperties(response).flatMap(prop => prop.children) };
        if (!child(child(properties, 'resourcetype'), 'calendar', CALDAV)) continue;
        const href = child(response, 'href')?.text.trim();
        if (!href) continue;
        const sourceID = trustedURL(href, home).href;
        const id = scopedID(sourceID, this.#login);
        const name = child(properties, 'displayname')?.text.trim() || 'Календарь';
        if (!calendars.has(id)) calendars.set(id, { id, sourceID, name, accountLogin: this.#login });
      }
    }
    if (!calendars.size) throw new Error('Доступные календари не найдены.');
    return Array.from(calendars.values()).sort((a, b) => a.name.localeCompare(b.name, 'ru'));
  }

  async #list(url, from, to, full = false) {
    return resourceProperties(await this.#xml(url, 'REPORT', '1', queryBody(from, to, full)), url);
  }

  async #download(reference) {
    const { body, etag } = await this.#request(reference.href, 'GET');
    return { href: reference.href, etag: etag ?? reference.etag, data: body, lastUsed: Date.now() };
  }

  async #batch(url, references) {
    let results;
    try {
      const hrefs = references.map(({ href }) => {
        const target = trustedURL(href, url);
        return `<d:href>${escapeXML(target.pathname + target.search)}</d:href>`;
      }).join('');
      results = resourceProperties(await this.#xml(url, 'REPORT', '1',
        `<c:calendar-multiget ${DAV_NAMESPACES}><d:prop><d:getetag/><c:calendar-data/></d:prop>${hrefs}</c:calendar-multiget>`), url);
    } catch (error) {
      if (!isStatus(error, CalDAVHttpError, UNSUPPORTED_REPORT) &&
          !isStatus(error, CalDAVResourceError, [...MISSING_RESOURCE, ...UNSUPPORTED_GET])) throw error;
      results = [];
    }
    const requested = new Set(references.map(reference => reference.href));
    if (results.some(resource => !requested.has(resource.href))) {
      throw new Error('Сервер вернул незапрошенное событие. Сохранённые встречи не изменены.');
    }
    const returned = new Map(results.map(resource => [resource.href, resource]));
    const downloaded = [];
    for (const reference of references) {
      const result = returned.get(reference.href);
      downloaded.push(result?.data !== undefined ? {
        ...result, etag: result.etag ?? reference.etag, lastUsed: Date.now()
      } : await this.#download(reference));
    }
    return downloaded;
  }

  async #fetchChanges(url, from, to, cached) {
    const references = await this.#list(url, from, to);
    const resources = [];
    const changed = [];
    for (const reference of references) {
      const old = cached[reference.href];
      if (reference.etag && old?.etag === reference.etag && typeof old.data === 'string') {
        resources.push({ ...old, href: reference.href, lastUsed: Date.now() });
      } else {
        changed.push(reference);
      }
    }
    for (let offset = 0; offset < changed.length; offset += 40) {
      resources.push(...await this.#batch(url, changed.slice(offset, offset + 40)));
    }
    return resources;
  }

  async #fetchFull(url, from, to) {
    const resources = await this.#list(url, from, to, true);
    if (resources.some(resource => resource.data === undefined)) {
      throw new Error('Сервер не вернул полные данные календаря. Кэш сохранён.');
    }
    return resources.map(resource => ({ ...resource, lastUsed: Date.now() }));
  }

  async #fetchResources(url, from, to, cached) {
    try {
      return await this.#fetchChanges(url, from, to, cached);
    } catch (error) {
      if (isStatus(error, CalDAVResourceError, MISSING_RESOURCE)) {
        try {
          return await this.#fetchChanges(url, from, to, cached);
        } catch (retryError) {
          if (!isStatus(retryError, CalDAVResourceError, [...MISSING_RESOURCE, ...UNSUPPORTED_GET]) &&
              !isStatus(retryError, CalDAVHttpError, UNSUPPORTED_REPORT)) throw retryError;
        }
      } else if (!isStatus(error, CalDAVResourceError, UNSUPPORTED_GET) &&
                 !isStatus(error, CalDAVHttpError, UNSUPPORTED_REPORT)) {
        throw error;
      }
      return this.#fetchFull(url, from, to);
    }
  }

  async meetings(calendar, from, to, { cached = {}, defaultTimeZone = 'Europe/Moscow', displayZone = localTimeZone() } = {}) {
    if (calendar.accountLogin && calendar.accountLogin.toLowerCase() !== this.#login.toLowerCase()) {
      throw new Error('Календарь относится к другому аккаунту.');
    }
    const start = new Date(from).getTime();
    const end = new Date(to).getTime();
    if (!(start < end)) throw new Error('Выберите корректный период календаря.');
    const url = trustedURL(calendar.sourceID ?? calendar.id);
    // A date-only event can fall outside the requested UTC bounds on the server.
    const padding = displayZone === defaultTimeZone ? 0 : 2 * DAY;
    const resources = await this.#fetchResources(url, start - padding, end + padding, cached);
    const failedResources = {};
    const accepted = {};
    const meetings = [];
    for (const resource of resources) {
      this.#signal?.throwIfAborted();
      try {
        const events = parseICalendar(resource.data, {
          calendar: { ...calendar, sourceID: url.href, accountLogin: this.#login },
          start, end, fallbackZone: defaultTimeZone, displayZone, resourceURL: resource.href, etag: resource.etag
        });
        for (const event of events) meetings.push(event);
        accepted[resource.href] = resource;
      } catch (error) {
        failedResources[resource.href] = error instanceof Error ? error.message : 'Некорректные данные события.';
      }
    }
    return { meetings, failedResources, resources: accepted, complete: Object.keys(failedResources).length === 0 };
  }
}

function mergeCalendarMeetings(previous, result) {
  if (result.complete) return result.meetings;
  const merged = new Map(result.meetings.map(event => [event.id, event]));
  for (const event of previous) {
    if (merged.has(event.id)) continue;
    if (!event.resourceURL || Object.hasOwn(result.failedResources, event.resourceURL)) merged.set(event.id, event);
  }
  return Array.from(merged.values());
}

function pruneCalendarResources(resources) {
  const kept = {};
  const recent = Object.values(resources).sort((a, b) => b.lastUsed - a.lastUsed).slice(0, 3000);
  let bytes = 0;
  for (const resource of recent) {
    bytes += Buffer.byteLength(resource.data);
    if (bytes > 24 * 1024 * 1024) break;
    kept[resource.href] = resource;
  }
  return kept;
}

module.exports = {
  YandexCalendarClient,
  mergeCalendarMeetings,
  pruneCalendarResources,
  isYandexEventURL,
  yandexCreateURL: (start, end, timeZone) => yandexCreateURL(start, { end, timeZone }),
  yandexEventURL: yandexEditURL
};
