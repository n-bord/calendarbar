'use strict';

const DAY = 86_400_000;
const HOUR = 3_600_000;
const MINUTE = 60_000;
const localTimeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
const telemostHosts = new Set([
  'telemost.yandex.ru', 'telemost.360.yandex.ru', 'telemost.yandex.com', 'telemost.360.yandex.com',
]);
const yandexCalendarHosts = new Set([
  'calendar.yandex.ru', 'calendar.360.yandex.ru', 'calendar.yandex.com', 'calendar.360.yandex.com',
]);
const formatters = new Map();

function timeFormatter(zone) {
  if (!formatters.has(zone)) {
    try {
      formatters.set(zone, new Intl.DateTimeFormat('en-GB', {
        timeZone: zone, calendar: 'gregory', numberingSystem: 'latn', hourCycle: 'h23',
        year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
      }));
    } catch {
      throw new Error(`Неизвестный часовой пояс ${zone}.`);
    }
  }
  return formatters.get(zone);
}

// Civil timestamps represent wall-clock components on a neutral UTC axis.
function civilTime(time, zone) {
  const rounded = Math.floor(Number(time) / 1_000) * 1_000;
  if (zone === 'UTC' || zone === 'Etc/UTC' || zone === 'GMT') return rounded;
  const values = Object.fromEntries(timeFormatter(zone).formatToParts(rounded).map(({ type, value }) => [type, Number(value)]));
  return civilDate(values.year, values.month - 1, values.day)
    + values.hour * HOUR + values.minute * MINUTE + values.second * 1_000;
}

function absoluteTime(civil, zone, { offset, nextValid = false } = {}) {
  if (zone === 'UTC' || zone === 'Etc/UTC' || zone === 'GMT') return civil;
  // Probe both sides of a transition to reject skipped wall times and choose
  // the earlier of the two instants when the clock repeats a wall time.
  const offsets = new Set([civil - DAY, civil + DAY].map(time => civilTime(time, zone) - time));
  const candidates = [...offsets].map(zoneOffset => civil - zoneOffset);
  const matches = candidates.filter(time => civilTime(time, zone) === civil);
  if (matches.includes(civil - offset)) return civil - offset;
  if (matches.length) return Math.min(...matches);
  return nextValid ? candidates.find(time => civilTime(time, zone) > civil) ?? null : null;
}

function dayKey(time, zone = localTimeZone()) {
  return new Date(civilTime(time, zone)).toISOString().slice(0, 10);
}

function displayed(meeting, zone = localTimeZone()) {
  if (!meeting.allDay || !meeting.allDayDates) return meeting;
  const atMidnight = value => absoluteTime(Date.parse(`${value}T00:00:00Z`), zone, { nextValid: true });
  return {
    ...meeting,
    start: atMidnight(meeting.allDayDates.start) ?? meeting.start,
    end: atMidnight(meeting.allDayDates.end) ?? meeting.end,
  };
}

function overlaps(meeting, from, to) {
  return meeting.start < to && (meeting.end > from || meeting.start >= from);
}

function scopedID(id, login) {
  return login ? `account:${Buffer.from(login, 'utf8').toString('base64')}:${id}` : id;
}

function safeWebURL(value) {
  try {
    const authority = /^https?:\/\/([^/?#]+)/i.exec(String(value))?.[1];
    if (!authority || authority.includes('@') || authority.includes('\\')) return null;
    const url = new URL(value);
    if (['http:', 'https:'].includes(url.protocol) && !url.username && !url.password && url.hostname) return url;
  } catch {
    // Ignore malformed links in otherwise valid events.
  }
  return null;
}

function hasExplicitPort(value) {
  return /^https?:\/\/[^/?#]*:\d+(?:[/?#]|$)/i.test(String(value));
}

function telemostDesktopURL(value) {
  const url = safeWebURL(value);
  if (!url || !telemostHosts.has(url.hostname) || url.port || hasExplicitPort(value)) return null;
  const path = url.pathname.split('/').filter(Boolean);
  if (path.length !== 2 || path[0] !== 'j' || !/^\d+$/.test(path[1])) return null;
  return `telemost://https://${url.hostname}/j/${path[1]}`;
}

function browserURL(value) {
  if (!telemostDesktopURL(value)) return value;
  const url = new URL(value);
  url.searchParams.set('skip_app', '1');
  return url.href;
}

function isUsableMeetingURL(value) {
  const url = safeWebURL(value);
  return Boolean(url && !yandexCalendarHosts.has(url.hostname) && url.hostname !== 'calendar.google.com'
    && (!telemostHosts.has(url.hostname) || telemostDesktopURL(value)));
}

function knownConference(value) {
  const url = safeWebURL(value);
  if (!url || !isUsableMeetingURL(value)) return false;
  const host = url.hostname;
  const path = url.pathname.toLowerCase();
  if (['meet.google.com', 'meet.jit.si'].includes(host)) return path.length > 1;
  if (/(^|\.)zoom\.(us|com)$/.test(host)) return /^\/(j|my|wc)\//.test(path);
  if (['teams.microsoft.com', 'teams.live.com', 'teams.cloud.microsoft'].includes(host)) {
    return path.startsWith('/l/meetup-join/') || path.startsWith('/meet/');
  }
  return host.endsWith('.webex.com') && (path.includes('/meet/') || path.includes('/join/')
    || [...url.searchParams.keys()].some(key => key.toUpperCase() === 'MTID'));
}

function urlsIn(text) {
  return (String(text).match(/https?:\/\/[^\s<>"]+/gi) || []).map(url => url.replace(/[).,;\]]+$/, ''));
}

function conferenceURL(explicitURLs = [], texts = []) {
  const candidates = [...explicitURLs, ...texts.flatMap(urlsIn)];
  return candidates.find(telemostDesktopURL) ?? candidates.find(knownConference) ?? explicitURLs.find(isUsableMeetingURL) ?? null;
}

function isYandexEventURL(value) {
  const url = safeWebURL(value);
  if (!url || url.protocol !== 'https:' || url.port || hasExplicitPort(value) || !yandexCalendarHosts.has(url.hostname)) {
    return false;
  }
  const parts = url.pathname.split('/').filter(Boolean);
  const index = parts.indexOf('event');
  return index !== -1 && (index + 1 < parts.length || url.searchParams.getAll('event_id').some(id => id.trim()));
}

function yandexCreateURL(start, { end = Number(start) + 30 * MINUTE, timeZone = localTimeZone() } = {}) {
  const local = time => new Date(civilTime(time, timeZone)).toISOString().slice(0, 19);
  const url = new URL('https://calendar.yandex.ru/week/create');
  url.search = new URLSearchParams({
    show_date: dayKey(start, timeZone), start: local(start), end: local(end), tz_id: timeZone,
  });
  return url.href;
}

function yandexEditURL(meeting, timeZone = localTimeZone()) {
  if (isYandexEventURL(meeting.sourceURL)) return meeting.sourceURL;
  const url = new URL('https://calendar.yandex.ru/day');
  url.search = new URLSearchParams({ show_date: meeting.allDayDates?.start ?? dayKey(meeting.start, timeZone), tz_id: timeZone });
  return url.href;
}

function invitationStatus(meeting, login = '') {
  const owner = (meeting.accountLogin || login).toLowerCase();
  if (!owner) return 'unknown';
  if (meeting.organizer?.toLowerCase() === owner) return 'organizer';
  const response = meeting.attendees?.find(person => person.email.toLowerCase() === owner)?.response?.toUpperCase();
  return { ACCEPTED: 'accepted', 'NEEDS-ACTION': 'needsAction', TENTATIVE: 'tentative', DECLINED: 'declined' }[response] ?? 'unknown';
}

function decode(text = '') {
  return text.replace(/\\([\s\S])/g, (_, char) => char === 'n' || char === 'N' ? '\n' : char);
}

function propertiesFrom(text) {
  const lines = text.replace(/\r\n?/g, '\n').replace(/\n[ \t]/g, '').split('\n');
  const blocks = [];
  let current;
  let nested = 0;
  for (const line of lines) {
    const upper = line.toUpperCase();
    if (upper === 'BEGIN:VEVENT') {
      if (current) throw new Error('Сервер вернул повреждённые данные календаря.');
      current = [];
      nested = 0;
    } else if (current && upper === 'END:VEVENT') {
      blocks.push(current);
      current = undefined;
    } else if (current && upper.startsWith('BEGIN:')) {
      nested++;
    } else if (current && upper.startsWith('END:')) {
      nested = Math.max(0, nested - 1);
    } else if (current && nested === 0) {
      const property = readProperty(line);
      if (property) current.push(property);
    }
  }
  if (current || !lines.some(line => line.toUpperCase() === 'BEGIN:VCALENDAR')) {
    throw new Error('Сервер вернул повреждённые данные календаря.');
  }
  return blocks;
}

function readProperty(line) {
  const tokens = [];
  let quoted = false;
  let start = 0;
  for (let index = 0; index < line.length; index++) {
    const char = line[index];
    if (char === '"') quoted = !quoted;
    if (quoted || (char !== ':' && char !== ';')) continue;
    tokens.push(line.slice(start, index));
    if (char === ':') {
      const name = tokens.shift().toUpperCase();
      const parameters = Object.create(null);
      for (const token of tokens) {
        const equal = token.indexOf('=');
        if (equal < 0) continue;
        const value = token.slice(equal + 1);
        parameters[token.slice(0, equal).toUpperCase()] = value.replace(/^"(.*)"$/, '$1');
      }
      return { name, parameters, value: line.slice(index + 1) };
    }
    start = index + 1;
  }
  return null;
}

const first = (component, name) => component?.find(property => property.name === name);
const all = (component, name) => component?.filter(property => property.name === name) ?? [];
const allDayProperty = property => property?.parameters.VALUE?.toUpperCase() === 'DATE' || /^\d{8}$/.test(property?.value);

function eventZone(property, fallback) {
  return /Z$/i.test(property.value) ? 'UTC' : property.parameters.TZID || fallback;
}

function readDate(property, fallback) {
  if (!property) return null;
  const match = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$/i.exec(property.value);
  if (!match) return null;
  const [year, month, day, hour = 0, minute = 0, second = 0] = match.slice(1).map(value => value === undefined ? undefined : Number(value));
  // Date.UTC treats years 0–99 as 1900–1999, so set the year explicitly.
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, 0);
  if (date.getUTCFullYear() !== year || date.getUTCMonth() + 1 !== month || date.getUTCDate() !== day
    || date.getUTCHours() !== hour || date.getUTCMinutes() !== minute || date.getUTCSeconds() !== second) return null;
  return absoluteTime(date.getTime(), eventZone(property, fallback));
}

function requiredDate(property, zone, message) {
  const date = readDate(property, zone);
  if (date === null) throw new Error(message);
  return date;
}

function addCalendarDays(start, days, zone) {
  if (!days) return start;
  const civil = civilTime(start, zone);
  const shifted = absoluteTime(civil + days * DAY, zone, { offset: civil - start, nextValid: true });
  if (!Number.isFinite(shifted)) throw new Error('Не удалось вычислить дату встречи.');
  return shifted;
}

function calendarDifference(start, end, zone) {
  const direction = Math.sign(end - start);
  let days = (midnight(civilTime(end, zone)) - midnight(civilTime(start, zone))) / DAY;
  let intermediate = addCalendarDays(start, days, zone);
  if ((intermediate - end) * direction > 0) {
    days -= direction;
    intermediate = addCalendarDays(start, days, zone);
  }
  return { days, milliseconds: end - intermediate };
}

function endAfter(start, { days, milliseconds }, zone) {
  return addCalendarDays(start, days, zone) + milliseconds;
}

function lengthOf(component, start, zone) {
  const isAllDay = allDayProperty(first(component, 'DTSTART') ?? first(component, 'RECURRENCE-ID'));
  const endProperty = first(component, 'DTEND');
  if (endProperty) {
    const end = requiredDate(endProperty, zone, 'Некорректное время окончания встречи.');
    if (end < start) throw new Error('Некорректное время окончания встречи.');
    if (isAllDay) return { days: calendarDifference(start, end, zone).days, milliseconds: 0 };
    return { days: 0, milliseconds: end - start };
  }
  const duration = first(component, 'DURATION')?.value;
  if (!duration) return { days: isAllDay ? 1 : 0, milliseconds: 0 };
  const parts = /^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(duration);
  if (!parts?.slice(1).some(value => value !== undefined)) throw new Error('Неизвестный формат длительности встречи.');
  const [weeks, days, hours, minutes, seconds] = parts.slice(1).map(value => Number(value ?? 0));
  if (![weeks, days, hours, minutes, seconds].every(Number.isSafeInteger)) {
    throw new Error('Неизвестный формат длительности встречи.');
  }
  return { days: weeks * 7 + days, milliseconds: hours * HOUR + minutes * MINUTE + seconds * 1_000 };
}

const weekdays = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];

function recurrenceRule(raw, zone) {
  const fields = Object.create(null);
  const allowed = new Set([
    'FREQ', 'INTERVAL', 'COUNT', 'UNTIL', 'WKST', 'BYMONTH', 'BYMONTHDAY', 'BYYEARDAY',
    'BYWEEKNO', 'BYDAY', 'BYHOUR', 'BYMINUTE', 'BYSECOND', 'BYSETPOS',
  ]);
  for (const item of raw.toUpperCase().split(';')) {
    const [key, value, ...rest] = item.split('=');
    if (!key || !value || rest.length || fields[key]) throw new Error('Некорректное правило повторения встречи.');
    if (!allowed.has(key)) throw new Error(`Параметр повторения ${key} пока не поддерживается.`);
    fields[key] = value;
  }

  const frequency = fields.FREQ;
  if (!['MINUTELY', 'HOURLY', 'DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'].includes(frequency)) {
    throw new Error(`Неизвестная частота повторения: ${frequency ?? 'не указана'}.`);
  }

  function number(value, key, min, max, noZero = false) {
    const parsed = Number(value);
    if (!/^[+-]?\d+$/.test(value) || parsed < min || parsed > max || (noZero && parsed === 0)) {
      throw new Error(`Некорректный параметр повторения ${key}.`);
    }
    return parsed;
  }

  function list(key, min, max, noZero) {
    const numbers = fields[key]?.split(',').map(value => number(value, key, min, max, noZero));
    return [...new Set(numbers)].sort((a, b) => a - b);
  }

  const weekStart = weekdays.indexOf(fields.WKST ?? 'MO');
  if (weekStart < 0) throw new Error('Некорректное начало недели WKST.');
  const interval = fields.INTERVAL ? number(fields.INTERVAL, 'INTERVAL', 1, 1_000_000) : 1;
  if (fields.COUNT && fields.UNTIL) throw new Error('Правило встречи одновременно содержит COUNT и UNTIL.');
  const count = fields.COUNT ? number(fields.COUNT, 'COUNT', 1, 1_000_000) : null;
  let until = null;
  if (fields.UNTIL) {
    const dateOnly = fields.UNTIL.length === 8;
    until = requiredDate({ value: fields.UNTIL, parameters: {} }, zone, 'Некорректная граница повторения UNTIL.');
    if (dateOnly) until = endAfter(until, { days: 1, milliseconds: -1 }, zone);
  }

  const months = list('BYMONTH', 1, 12);
  const monthDays = list('BYMONTHDAY', -31, 31, true);
  const yearDays = list('BYYEARDAY', -366, 366, true);
  const weekNumbers = list('BYWEEKNO', -53, 53, true);
  const hours = list('BYHOUR', 0, 23);
  const minutes = list('BYMINUTE', 0, 59);
  const seconds = list('BYSECOND', 0, 59);
  const positions = list('BYSETPOS', -366, 366, true);
  const days = fields.BYDAY?.split(',').map(value => {
    const match = /^([+-]?\d+)?(SU|MO|TU|WE|TH|FR|SA)$/.exec(value);
    if (!match) throw new Error('Некорректный день недели в повторении BYDAY.');
    if (match[1] && !['MONTHLY', 'YEARLY'].includes(frequency)) {
      throw new Error('Некорректный порядковый номер дня BYDAY.');
    }
    return { day: weekdays.indexOf(match[2]), ordinal: match[1] ? number(match[1], 'BYDAY', -53, 53, true) : null };
  }) ?? [];
  if (frequency === 'WEEKLY' && monthDays.length) throw new Error('BYMONTHDAY нельзя использовать с WEEKLY.');
  if (frequency !== 'YEARLY' && weekNumbers.length) throw new Error('BYWEEKNO требует частоты YEARLY.');
  if (['DAILY', 'WEEKLY', 'MONTHLY'].includes(frequency) && yearDays.length) {
    throw new Error('BYYEARDAY несовместим с указанной частотой.');
  }

  return { frequency, count, until, interval, weekStart, months, monthDays, yearDays, weekNumbers, hours, minutes, seconds, positions, days };
}

function civilDate(year, month = 0, day = 1) {
  const date = new Date(0);
  date.setUTCFullYear(year, month, day);
  return date.getTime();
}

const midnight = civil => Math.floor(civil / DAY) * DAY;
const weekday = civil => new Date(civil).getUTCDay();
const weekOf = (civil, weekStart) => midnight(civil) - ((weekday(civil) - weekStart + 7) % 7) * DAY;
const firstWeekOfYear = (year, weekStart) => weekOf(civilDate(year, 0, 4), weekStart);

function periodIndex(civil, rule) {
  if (rule.frequency === 'DAILY') return Math.floor(civil / DAY);
  if (rule.frequency === 'WEEKLY') return (weekOf(civil, rule.weekStart) - weekOf(0, rule.weekStart)) / (7 * DAY);
  const date = new Date(civil);
  if (rule.frequency === 'MONTHLY') return date.getUTCFullYear() * 12 + date.getUTCMonth();
  return date.getUTCFullYear();
}

function periodBounds(period, rule) {
  if (rule.frequency === 'DAILY') {
    const start = period * DAY;
    return [start, start + DAY];
  }
  if (rule.frequency === 'WEEKLY') {
    const start = weekOf(0, rule.weekStart) + period * 7 * DAY;
    return [start, start + 7 * DAY];
  }
  if (rule.frequency === 'MONTHLY') {
    const year = Math.floor(period / 12);
    const month = period - year * 12;
    return [civilDate(year, month), civilDate(year, month + 1)];
  }
  if (rule.weekNumbers.length) return [firstWeekOfYear(period, rule.weekStart), firstWeekOfYear(period + 1, rule.weekStart)];
  return [civilDate(period), civilDate(period + 1)];
}

function matchesOrdinal(options, index, size) {
  return !options.length || options.includes(index) || options.includes(index - size - 1);
}

function matchesDate(civil, base, rule, period, periodStart, periodEnd) {
  const date = new Date(civil);
  const year = date.getUTCFullYear();
  const month = date.getUTCMonth();
  const day = date.getUTCDate();
  const yearStart = civilDate(year);
  const yearEnd = civilDate(year + 1);
  const monthLength = new Date(civilDate(year, month + 1, 0)).getUTCDate();
  if (rule.months.length && !rule.months.includes(month + 1)) return false;
  if (!matchesOrdinal(rule.monthDays, day, monthLength)) return false;
  if (!matchesOrdinal(rule.yearDays, (civil - yearStart) / DAY + 1, (yearEnd - yearStart) / DAY)) return false;
  if (!matchesOrdinal(rule.weekNumbers, Math.floor((civil - periodStart) / (7 * DAY)) + 1, (periodEnd - periodStart) / (7 * DAY))) {
    return false;
  }
  if (rule.days.length) {
    const matches = rule.days.some(request => {
      if (request.day !== date.getUTCDay()) return false;
      if (request.ordinal === null) return true;
      const inYear = rule.frequency === 'YEARLY' && !rule.months.length && !rule.weekNumbers.length;
      const dayIndex = inYear ? (civil - yearStart) / DAY : day - 1;
      const daysAfter = inYear ? (yearEnd - civil) / DAY - 1 : monthLength - day;
      return request.ordinal === Math.floor(dayIndex / 7) + 1 || request.ordinal === -Math.floor(daysAfter / 7) - 1;
    });
    if (!matches) return false;
  } else if (rule.frequency === 'WEEKLY') {
    return date.getUTCDay() === base.getUTCDay();
  }
  const explicitlyExpanded = rule.days.length || rule.monthDays.length || rule.yearDays.length || rule.weekNumbers.length;
  if (!explicitlyExpanded && rule.frequency === 'MONTHLY') return day === base.getUTCDate();
  if (!explicitlyExpanded && rule.frequency === 'YEARLY') {
    return year === period && day === base.getUTCDate() && (rule.months.length || month === base.getUTCMonth());
  }
  return true;
}

function recurrenceDates(raw, start, zone, from, to) {
  const rule = recurrenceRule(raw, zone);
  const civilStart = civilTime(start, zone);
  const base = new Date(civilStart);
  const fixedMinute = rule.frequency === 'MINUTELY';
  const fixedHour = fixedMinute || rule.frequency === 'HOURLY';
  // Hourly and minutely intervals advance by elapsed time across the repeated hour.
  const elapsedStep = rule.frequency === 'HOURLY' ? HOUR : rule.frequency === 'MINUTELY' ? MINUTE : 0;
  const periodOrigin = elapsedStep ? start - (civilStart % elapsedStep + elapsedStep) % elapsedStep : start;
  const originalPeriod = elapsedStep ? 0 : periodIndex(civilStart, rule);
  const limit = Math.min(to - 1, rule.until ?? to);
  if (limit < start || from > limit) return [];
  const firstPeriod = elapsedStep
    ? Math.floor((from - periodOrigin) / elapsedStep) : periodIndex(civilTime(from - 2 * DAY, zone), rule);
  const lastPeriod = elapsedStep
    ? Math.floor((limit - periodOrigin) / elapsedStep) : periodIndex(civilTime(limit + 2 * DAY, zone), rule);
  const firstIndex = rule.count ? 0 : Math.max(0, Math.floor((firstPeriod - originalPeriod) / rule.interval));
  const result = [];
  const deadline = Date.now() + 3_000;
  let seen = 0;
  let examined = 0;
  for (let index = firstIndex; ; index++) {
    const period = originalPeriod + index * rule.interval;
    if (period > lastPeriod) break;
    if (Date.now() >= deadline) throw new Error('Правило встречи создаёт слишком много повторов. Расчёт остановлен.');
    const clockPeriod = periodOrigin + period * elapsedStep;
    const clockTime = elapsedStep ? civilTime(clockPeriod, zone) : null;
    const [firstTime, periodEnd] = elapsedStep ? [clockTime, clockTime + elapsedStep] : periodBounds(period, rule);
    const candidates = [];
    for (let day = midnight(firstTime); day < periodEnd; day += DAY) {
      if (!matchesDate(day, base, rule, period, firstTime, periodEnd)) continue;
      const first = new Date(firstTime);
      const hours = fixedHour ? [first.getUTCHours()] : rule.hours.length ? rule.hours : [base.getUTCHours()];
      const minutes = fixedMinute ? [first.getUTCMinutes()] : rule.minutes.length ? rule.minutes : [base.getUTCMinutes()];
      const seconds = rule.seconds.length ? rule.seconds : [base.getUTCSeconds()];
      for (const hour of hours) {
        if (fixedHour && rule.hours.length && !rule.hours.includes(hour)) continue;
        for (const minute of minutes) {
          if (fixedMinute && rule.minutes.length && !rule.minutes.includes(minute)) continue;
          for (const second of seconds) {
            if (++examined > 500_000 || Date.now() >= deadline) {
              throw new Error('Правило встречи создаёт слишком много повторов. Расчёт остановлен.');
            }
            const absolute = elapsedStep
              ? clockPeriod + (fixedMinute ? 0 : minute * MINUTE) + second * 1_000
              : absoluteTime(day + hour * HOUR + minute * MINUTE + second * 1_000, zone);
            if (absolute !== null) candidates.push(absolute);
          }
        }
      }
    }
    candidates.sort((a, b) => a - b);
    const selected = rule.positions.length
      ? [...new Set(rule.positions.map(position => candidates.at(position > 0 ? position - 1 : position)))]
        .filter(value => value !== undefined).sort((a, b) => a - b)
      : candidates;
    for (const date of selected) {
      if (date < start) continue;
      if (date > limit) return result;
      if (date >= from) result.push(date);
      if (++seen === rule.count) return result;
      if (result.length >= 50_000) throw new Error('Правило встречи создаёт слишком много повторов. Расчёт остановлен.');
    }
  }
  return result;
}

function makeMeeting(component, master, start, original, zone, length, uid, options) {
  const property = name => first(component, name) ?? first(master, name);
  const allDay = allDayProperty(property('DTSTART') ?? property('RECURRENCE-ID'));
  const attendeeProperties = all(component, 'ATTENDEE');
  const people = attendeeProperties.length ? attendeeProperties : all(master, 'ATTENDEE');
  const email = value => value.replace(/^mailto:/i, '');
  const attendees = people.map(({ value, parameters }) => ({
    email: email(value), name: decode(parameters.CN), optional: parameters.ROLE?.toUpperCase() === 'OPT-PARTICIPANT',
    response: (parameters.PARTSTAT ?? 'NEEDS-ACTION').toUpperCase(),
  }));
  const details = decode(property('DESCRIPTION')?.value);
  const location = decode(property('LOCATION')?.value);
  const urls = urlsIn(property('URL')?.value ?? '');
  const conferences = all(component, 'CONFERENCE');
  const explicitLinks = (conferences.length ? conferences : all(master, 'CONFERENCE'))
    .flatMap(conference => urlsIn(conference.value));
  const series = `${options.calendarID}|${uid}`;
  const end = endAfter(start, length, zone);
  const allDayDates = allDay ? { start: dayKey(start, zone), end: dayKey(end, zone) } : null;
  const meeting = {
    id: scopedID(`${series}|${original === null ? 'master' : (original / 1_000).toFixed(1)}`, options.accountLogin),
    seriesID: scopedID(series, options.accountLogin),
    calendarID: scopedID(options.calendarID, options.accountLogin),
    calendarName: options.calendarName,
    accountLogin: options.accountLogin || null,
    title: decode(property('SUMMARY')?.value ?? 'Без названия'),
    start, end, allDay, allDayDates, details, location,
    link: conferenceURL([...explicitLinks, ...urls], [location, details]),
    attendees, organizer: email(property('ORGANIZER')?.value ?? ''),
    cancelled: property('STATUS')?.value.toUpperCase() === 'CANCELLED',
    uid, recurrenceRule: property('RRULE')?.value ?? null, originalStart: original,
    isRecurring: original !== null || Boolean(property('RRULE')),
    sourceURL: urls.find(isYandexEventURL) ?? null,
    resourceURL: options.resourceURL ?? null,
    etag: options.etag ?? null,
    isFree: property('TRANSP')?.value.toUpperCase() === 'TRANSPARENT',
  };
  return options.displayZone ? displayed(meeting, options.displayZone) : meeting;
}

function dateList(component, name, zone) {
  return all(component, name).flatMap(property => property.value.split(',').map(value => {
    if (value.includes('/')) throw new Error('RDATE с периодом пока не поддерживается.');
    return requiredDate({ ...property, value }, zone, `Не удалось прочитать дату ${name}.`);
  }));
}

function expandSeries(components, uid, options) {
  const fallback = options.defaultTimeZone;
  const withinRange = meeting => options.from === undefined || overlaps(meeting, options.from, options.to);
  const masters = components.filter(component => !first(component, 'RECURRENCE-ID'));
  if (masters.length > 1) throw new Error('Несколько основных записей одной серии.');
  if (!masters.length) {
    const instances = new Map();
    for (const component of components) {
      const recurrence = first(component, 'RECURRENCE-ID');
      const original = requiredDate(recurrence, fallback, 'Не удалось прочитать RECURRENCE-ID.');
      const property = first(component, 'DTSTART') ?? recurrence;
      const zone = eventZone(property, fallback);
      const start = requiredDate(property, zone, 'Не удалось прочитать дату повтора.');
      const sequence = Number(first(component, 'SEQUENCE')?.value) || 0;
      if (sequence >= (instances.get(original)?.sequence ?? -Infinity)) {
        instances.set(original, { sequence, meeting: makeMeeting(component, null, start, original, zone,
          lengthOf(component, start, zone), uid, options) });
      }
    }
    return [...instances.values()].map(({ meeting }) => meeting).filter(withinRange);
  }

  const [master] = masters;
  const startProperty = first(master, 'DTSTART');
  const start = requiredDate(startProperty, fallback, 'Не удалось прочитать начало встречи.');
  const zone = eventZone(startProperty, fallback);
  const masterLength = lengthOf(master, start, zone);
  const recurring = components.length > 1 || master.some(property => ['RRULE', 'RDATE', 'EXDATE', 'EXRULE'].includes(property.name));
  if (!recurring) return [makeMeeting(master, null, start, null, zone, masterLength, uid, options)].filter(withinRange);

  if (!Number.isFinite(options.from) || !Number.isFinite(options.to)) {
    throw new Error('Для повторяющейся встречи нужен диапазон загрузки.');
  }
  if (first(master, 'EXRULE')) throw new Error('Устаревшее исключение EXRULE пока не поддерживается.');
  const rules = all(master, 'RRULE');
  if (rules.length > 1) throw new Error('Несколько RRULE в одной серии пока не поддерживаются.');
  const overrides = new Map();
  let movePadding = 0;
  function componentStart(component, original) {
    const property = first(component, 'DTSTART');
    return property ? requiredDate(property, zone, 'Не удалось прочитать перенесённое начало встречи.') : original;
  }

  for (const component of components) {
    const property = first(component, 'RECURRENCE-ID');
    if (!property) continue;
    const original = requiredDate(property, zone, 'Некорректная дата исключения серии.');
    const range = property.parameters.RANGE?.toUpperCase();
    if (range && range !== 'THISANDFUTURE') throw new Error('Неизвестный вариант переноса RANGE.');
    const sequence = Number(first(component, 'SEQUENCE')?.value) || 0;
    if (sequence < (overrides.get(original)?.sequence ?? -Infinity)) continue;
    const moved = componentStart(component, original);
    movePadding = Math.max(movePadding, Math.abs(moved - original));
    overrides.set(original, { component, sequence, moved, following: range === 'THISANDFUTURE' });
  }

  const datePadding = allDayProperty(startProperty) && options.displayZone ? 2 * DAY : DAY;
  const duration = endAfter(start, masterLength, zone) - start;
  const searchStart = options.from - duration - movePadding - datePadding;
  const searchEnd = options.to + movePadding + datePadding;
  const dates = new Set([start, ...dateList(master, 'RDATE', zone), ...overrides.keys()]);
  if (rules.length) {
    for (const date of recurrenceDates(rules[0].value, start, zone, searchStart, searchEnd)) dates.add(date);
  }
  const excluded = new Set(dateList(master, 'EXDATE', zone));
  const meetings = [];
  let activeOverride;
  for (const original of [...dates].sort((a, b) => a - b)) {
    const exact = overrides.get(original);
    if (exact?.following) activeOverride = { ...exact, shift: calendarDifference(original, exact.moved, zone) };
    if (excluded.has(original) && !exact) continue;
    const override = exact ?? activeOverride;
    const component = override?.component ?? master;
    let occurrence = original;
    if (exact) occurrence = exact.moved;
    else if (activeOverride) occurrence = endAfter(original, activeOverride.shift, zone);
    const length = override && (first(component, 'DTEND') || first(component, 'DURATION'))
      ? lengthOf(component, override.moved, zone) : masterLength;
    const meeting = makeMeeting(component, master, occurrence, original, zone, length, uid, options);
    if (withinRange(meeting)) meetings.push(meeting);
  }
  return meetings;
}

function parseCalendar(text, {
  calendarID = '', calendarName = '', accountLogin = '', defaultTimeZone = localTimeZone(), displayZone,
  resourceURL, etag, from, to,
} = {}) {
  const options = { calendarID, calendarName, accountLogin, defaultTimeZone, displayZone, resourceURL, etag };
  if (from != null && to != null) {
    options.from = Number(from);
    options.to = Number(to);
    if (!Number.isFinite(options.from) || !Number.isFinite(options.to) || options.to < options.from) {
      throw new Error('Некорректный диапазон загрузки календаря.');
    }
  }
  const groups = new Map();
  for (const component of propertiesFrom(text)) {
    const uid = first(component, 'UID')?.value;
    if (!uid) throw new Error('Не удалось прочитать UID встречи.');
    if (!groups.has(uid)) groups.set(uid, []);
    groups.get(uid).push(component);
  }
  const meetings = [];
  for (const [uid, components] of groups) {
    try {
      for (const meeting of expandSeries(components, uid, options)) meetings.push(meeting);
    } catch (error) {
      const title = decode(first(components[0], 'SUMMARY')?.value ?? 'Без названия');
      throw new Error(`Встреча «${title}»: ${error.message}`, { cause: error });
    }
  }
  return meetings.sort((a, b) => a.start - b.start || a.id.localeCompare(b.id));
}

function parseICalendar(text, { calendar = {}, start, end, fallbackZone, displayZone, resourceURL, etag } = {}) {
  return parseCalendar(text, {
    calendarID: calendar.sourceID ?? calendar.id, calendarName: calendar.name, accountLogin: calendar.accountLogin,
    defaultTimeZone: fallbackZone, displayZone, resourceURL, etag, from: start, to: end,
  });
}

module.exports = {
  parseCalendar, parseICalendar, conferenceURL, telemostDesktopURL, browserURL, isUsableMeetingURL,
  isYandexEventURL, yandexCreateURL, yandexEditURL, dayKey, displayed, overlaps, invitationStatus, scopedID,
};
