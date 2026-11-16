'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');

const DAY = 86_400_000;
const MINUTE = 60_000;
const profileDefaults = {
  zone: 'Europe/Moscow', notifyNew: true, notifyChanges: true, notifyMinorChanges: false,
  firstReminderEnabled: true, firstReminderMinutes: 15, secondReminderEnabled: true, secondReminderMinutes: 5,
  workdayStartHour: 9, workdayStartMinute: 0, workdayEndHour: 18, workdayEndMinute: 0,
  dailyOverviewEnabled: false, dailyOverviewHour: 9,
  dailyOverviewMinute: 0, menuCountdownWindow: 60, menuMeetingsMode: 'currentAndUpcoming'
};
const globalDefaults = {
  appearance: 'system', autoStart: false, workdayRefreshMinutes: 5, outsideRefreshMinutes: 30,
  workdayOnly: true, calendarView: 'week'
};

function dayStart(value) {
  const date = new Date(value);
  date.setHours(0, 0, 0, 0);
  return +date;
}

function addDays(value, amount) {
  const date = new Date(value);
  date.setDate(date.getDate() + amount);
  return +date;
}

function allDayBoundary(value) {
  const [year, month, day] = value.split('-').map(Number);
  return +new Date(year, month - 1, day);
}

function displayedTime(meeting) {
  const dates = meeting.allDay && meeting.allDayDates;
  if (!dates?.start || !dates?.end) return meeting;
  return { ...meeting, start: allDayBoundary(dates.start), end: allDayBoundary(dates.end) };
}

function intersects(meeting, from, to) {
  const { start, end } = displayedTime(meeting);
  return start < to && (end > from || (start === end && start >= from));
}

function combineRanges(ranges) {
  const combined = [];
  for (const range of ranges.slice().sort((a, b) => a.from - b.from)) {
    const last = combined.at(-1);
    if (last && last.to >= range.from) last.to = Math.max(last.to, range.to);
    else combined.push({ from: range.from, to: range.to });
  }
  return combined;
}

function intersectRanges(left, right) {
  const result = [];
  let i = 0, j = 0;
  while (i < left.length && j < right.length) {
    const from = Math.max(left[i].from, right[j].from);
    const to = Math.min(left[i].to, right[j].to);
    if (from < to) result.push({ from, to });
    if (left[i].to < right[j].to) i++;
    else j++;
  }
  return result;
}

function changesBetween(old, current, seenSeries, now) {
  const previous = new Map(old.map(event => [event.id, event]));
  const major = ['start', 'end', 'allDay', 'allDayDates', 'title', 'location', 'link', 'cancelled'];
  const minor = ['details', 'organizer', 'isFree'];
  const differs = (meeting, prior, keys) => keys.some(key =>
    JSON.stringify(meeting[key]) !== JSON.stringify(prior[key]));
  const attendeeSignature = event => JSON.stringify((event.attendees ?? []).slice().sort((a, b) =>
    String(a.email ?? '').localeCompare(String(b.email ?? ''))));
  const changes = [];
  for (const meeting of current) {
    if (meeting.end <= now) continue;
    const prior = previous.get(meeting.id);
    let kind;
    let important = true;
    if (!prior && !meeting.cancelled && !seenSeries.has(meeting.seriesID)) kind = 'new';
    if (prior) {
      important = differs(meeting, prior, major);
      if (important || differs(meeting, prior, minor) || attendeeSignature(meeting) !== attendeeSignature(prior)) {
        kind = meeting.cancelled && !prior.cancelled ? 'cancelled' : 'changed';
      }
    }
    if (kind) changes.push({ id: randomUUID(), login: meeting.accountLogin, kind, meeting,
      previous: prior, important, at: now, unread: true });
  }
  return changes;
}

function reminderPlans(accounts, now, declined, grace = 0) {
  const plans = [];
  for (const account of accounts) {
    const settings = { ...profileDefaults, ...account.settings };
    const defaults = [];
    if (settings.firstReminderEnabled) defaults.push(settings.firstReminderMinutes);
    if (settings.secondReminderEnabled) defaults.push(settings.secondReminderMinutes);
    const enabled = new Set(account.calendars.filter(calendar => calendar.notify).map(calendar => calendar.id));
    const cache = Object.values(account.cache).flatMap(calendar => Object.values(calendar.meetings));
    const events = new Map([...account.snoozes.map(item => item.meeting), ...cache].map(event => [event.id, event]));
    const snoozes = new Map(account.snoozes.map(item => [item.meeting.id, item]));
    for (const event of events.values()) {
      const meeting = displayedTime(event);
      if (!enabled.has(meeting.calendarID) || meeting.allDay || meeting.cancelled || meeting.end <= now ||
          declined(meeting, account.login)) continue;
      const override = account.reminders[meeting.id] ?? account.reminders[meeting.seriesID];
      if (override?.muted) continue;
      const pending = snoozes.get(meeting.id);
      const snooze = pending?.at >= now - grace && pending?.meeting.start === meeting.start &&
        pending.meeting.end === meeting.end && pending.meeting.link === meeting.link ? pending : null;
      const moments = [...new Set(override?.minutes ?? defaults)].map(minutes => [meeting.start - minutes * MINUTE, minutes])
        .filter(([at]) => !snooze || at > snooze.at);
      if (snooze) moments.push([snooze.at, null]);
      for (const [at, minutes] of moments) {
        if (at < now - grace || at >= meeting.end) continue;
        const id = JSON.stringify([meeting.id, meeting.start, meeting.end, meeting.link, at, minutes]);
        if (!account.delivered[id]) plans.push({ id, at, minutes, meeting, account });
      }
    }
  }
  return plans.sort((a, b) => a.at - b.at).slice(0, 60);
}

function loadDisk(filename) {
  const initial = { globals: {}, unlinkedSettings: {}, primaryLogin: '', accounts: [], localPins: [], overviewDay: '' };
  try {
    return { ...initial, ...JSON.parse(fs.readFileSync(filename, 'utf8')) };
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return initial;
  }
}

function saveDisk(filename, disk) {
  fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
  const tmp = filename + '.tmp';
  try {
    fs.writeFileSync(tmp, JSON.stringify(disk), { mode: 0o600 });
    fs.renameSync(tmp, filename);
  } catch (error) {
    try { fs.rmSync(tmp, { force: true }); } catch {}
    throw error;
  }
}

function newProfile(login) {
  return { login, label: '', active: true, visible: true, settings: {}, calendars: [], cache: {},
    background: [], initialized: false, seenSeries: {}, reminders: {}, colors: {}, pins: [],
    snoozes: [], delivered: {}, activity: [], hiddenLast: '', lastAttempt: 0, lastSync: 0 };
}

function withoutCalendarCache(account, now) {
  return { ...account, cache: {}, background: [], initialized: false, seenSeries: {},
    baselineCalendars: [], lastAttempt: now, lastSync: 0, error: '' };
}

function calendarCacheBytes(account) {
  // The Windows data file contains both cache and settings. Count the UTF-8
  // bytes of the cached payload beyond its empty JSON containers.
  const payloads = [[account.cache ?? {}, 2], [account.background ?? [], 2],
    [account.seenSeries ?? {}, 2], [account.baselineCalendars ?? [], 2]];
  return payloads.reduce((sum, [value, emptySize]) =>
    sum + Buffer.byteLength(JSON.stringify(value)) - emptySize, 0);
}

module.exports = { DAY, MINUTE, profileDefaults, globalDefaults, dayStart, addDays, displayedTime, intersects,
  combineRanges, intersectRanges, changesBetween, reminderPlans, loadDisk, saveDisk, newProfile,
  withoutCalendarCache, calendarCacheBytes };
