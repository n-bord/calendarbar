'use strict';

const { app, BrowserWindow, Tray, Menu, Notification, ipcMain, shell, nativeTheme, nativeImage, screen, powerMonitor,
  safeStorage, session, dialog, clipboard } = require('electron');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { randomUUID } = require('node:crypto');
const { YandexCalendarClient, mergeCalendarMeetings, pruneCalendarResources,
  yandexCreateURL, yandexEventURL } = require('./accounts.cjs');
const { browserURL, telemostDesktopURL, invitationStatus, isUsableMeetingURL, scopedID } = require('./calendar.cjs');
const { DAY, MINUTE, profileDefaults, globalDefaults, dayStart, addDays, displayedTime, intersects,
  combineRanges, intersectRanges, changesBetween, reminderPlans, loadDisk, saveDisk, newProfile,
  withoutCalendarCache, calendarCacheBytes } = require('./store.cjs');

const ID = 'com.nbord.CalendarBar';
const SCHEME = 'calendarbar-action';
const TOAST_ACTIVATOR = '{9DFB9A2E-FFC8-4D2E-91C3-EFE12E7C9A9B}';
const iconPath = path.join(__dirname, '../assets/icon.png');
const rendererPath = path.join(__dirname, 'index.html');
const rendererURL = pathToFileURL(rendererPath).href;
const windowOptions = {
  calendar: ['CalendarBar', 1240, 780, 860, 600],
  settings: ['Настройки CalendarBar', 800, 635, 720, 550],
  search: ['Поиск встреч', 840, 645, 640, 500],
  meeting: ['Встреча', 600, 650, 500, 460],
  activity: ['Изменения и напоминания', 600, 620, 500, 470],
  pinned: ['Закреплённые встречи', 520, 490, 440, 380],
  tray: ['CalendarBar', 364, 280, 0, 0]
};

let disk;
let tray;
let exiting = false;
let syncCount = 0;
let connecting = false;
let syncMessage = '';
let notificationStatus = '';
let focusToken = 0;
let reminderTimer;
let refreshTimer;
let trayHeight = windowOptions.tray[2];
let lastSessionReminderCheck = Date.now();
let queue = Promise.resolve();
const windows = new Map();
const focuses = new Map();
const cacheRevisions = new Map();
const passwordCache = new Map();
const pendingLoads = new Map();
const memoWindows = new Map();
const alerts = new Map();
const appData = () => path.join(app.getPath('userData'), 'calendarbar.json');
const globals = () => ({ ...globalDefaults, ...disk.globals });
const primary = () => disk.accounts.find(account => account.login === disk.primaryLogin);
const activeAccounts = () => disk.accounts.filter(account => account.active);
const preferences = account => ({ ...profileDefaults, ...(account ? account.settings : disk.unlinkedSettings) });
const accountName = account => account.label || account.login;
const cacheMeetings = account => Object.values(account.cache).flatMap(value => Object.values(value.meetings));
const allMeetings = () => activeAccounts().flatMap(cacheMeetings);
const visibleAccountCalendars = account => account.visible ? account.calendars.filter(item => item.listed && item.visible) : [];
const isDeclined = (meeting, login) => String(invitationStatus(meeting, login)).toLowerCase() === 'declined';
const viewOf = contents => [...windows].find(([, window]) => window.webContents === contents)?.[0];

function coverage() {
  const calendars = activeAccounts().flatMap(account =>
    visibleAccountCalendars(account).map(calendar => account.cache[calendar.id]?.coverage ?? []));
  if (!calendars.length) return [];
  return calendars.reduce(intersectRanges);
}

function state(view) {
  const accounts = activeAccounts();
  const focus = focuses.get(view);
  const meetings = allMeetings();
  const focusMeeting = meetings.find(meeting => meeting.id === focus?.meeting) ??
    accounts.flatMap(account => [...account.activity.map(entry => entry.meeting), ...account.snoozes.map(item => item.meeting)])
      .find(meeting => meeting.id === focus?.meeting);
  return {
    version: app.getVersion(), appearance: globals().appearance, settings: { ...preferences(primary()), ...globals() },
    accounts: disk.accounts.map(({ login, label, active, visible, calendars, error, settings }) =>
      ({ login, label, active, visible, calendars, error, settings: { ...profileDefaults, ...settings } })),
    primaryLogin: disk.primaryLogin,
    ...(view === 'settings' && {
      cacheBytes: Object.fromEntries(disk.accounts.map(account => [account.login, calendarCacheBytes(account)]))
    }),
    cacheRevisions: Object.fromEntries(cacheRevisions),
    meetings: meetings.map(displayedTime).sort((a, b) => a.start - b.start || a.end - b.end),
    focusMeeting: focusMeeting ? displayedTime(focusMeeting) : null, focusDate: focus?.date,
    focusQuery: focus?.query, focusToken: focus?.token ?? 0,
    pins: [...accounts.flatMap(account => account.pins), ...disk.localPins],
    activity: accounts.flatMap(account => account.activity).sort((a, b) => b.at - a.at),
    snoozes: accounts.flatMap(account => account.snoozes),
    reminders: Object.assign({}, ...accounts.map(account => account.reminders)),
    colors: Object.assign({}, ...accounts.map(account => account.colors)),
    hiddenLast: Object.fromEntries(accounts.map(account => [account.login, account.hiddenLast])),
    lastSync: accounts.length ? Math.min(...accounts.map(account => account.lastSync || 0)) : 0,
    syncing: connecting || syncCount > 0, syncMessage, notificationStatus, coverage: coverage(),
    warning: accounts.filter(account => account.error).map(account => accountName(account) + ' · ' + account.error).join('\n'),
    now: Date.now()
  };
}

function visibleMeetings() {
  const ids = new Set(activeAccounts().flatMap(account => visibleAccountCalendars(account).map(item => item.id)));
  return allMeetings().filter(meeting => ids.has(meeting.calendarID) && !meeting.cancelled &&
    !isDeclined(meeting, meeting.accountLogin));
}

function updateTray() {
  if (!tray) return;
  const now = Date.now();
  const window = preferences(primary()).menuCountdownWindow;
  const events = visibleMeetings().filter(meeting => !meeting.allDay);
  let label = '';
  if (window > 0 && events.some(event => event.start <= now && event.end > now)) label = 'Встреча по плану';
  if (window > 0 && !label) {
    const next = events.reduce((earliest, event) => event.start > now ? Math.min(earliest, event.start) : earliest, Infinity);
    const minutes = Math.ceil((next - now) / MINUTE);
    if (minutes <= window) label = 'До встречи ' + (minutes >= 60 ?
      Math.floor(minutes / 60) + ' ч ' + (minutes % 60 ? minutes % 60 + ' мин' : '') : minutes + ' мин');
  }
  tray.setToolTip(label ? 'CalendarBar · ' + label.trim() : 'CalendarBar');
  if (process.platform === 'darwin') tray.setTitle(label.trim());
}

function publish() {
  if (exiting) return;
  updateTray();
  for (const [view, window] of windows) {
    if (window.isVisible() && !window.webContents.isLoading()) window.webContents.send('calendarbar:update', state(view));
  }
}

function persist() {
  saveDisk(appData(), disk);
}

function changed() {
  persist();
  publish();
  scheduleNotifications();
}

function clearCalendarCache(login) {
  if (connecting || syncCount) throw new Error('Дождитесь окончания загрузки календаря и попробуйте снова.');
  if (login !== undefined) accountFor(login);
  const now = Date.now();
  const cleared = new Set();
  let releasedBytes = 0;
  const accounts = disk.accounts.map(account => {
    if (login !== undefined && account.login !== login) return account;
    const bytes = calendarCacheBytes(account);
    if (!bytes) return account;
    releasedBytes += bytes;
    cleared.add(account.login);
    return withoutCalendarCache(account, now);
  });
  if (!cleared.size) return { releasedBytes };
  const next = { ...disk, accounts };
  saveDisk(appData(), next);
  disk = next;

  const prefixes = [...cleared].map(login => scopedID('', login));
  const wasCleared = id => typeof id === 'string' && prefixes.some(prefix => id.startsWith(prefix));
  for (const login of cleared) cacheRevisions.set(login, (cacheRevisions.get(login) ?? 0) + 1);
  for (const [view, focus] of focuses) {
    if (wasCleared(focus.meeting)) focuses.set(view, { token: ++focusToken });
  }
  for (const { id } of alerts.values()) {
    if (wasCleared(id)) closeMeetingToasts(id);
  }
  syncMessage = '';
  publish();
  scheduleNotifications();
  return { releasedBytes };
}

function openWindow(view, payload = {}) {
  if (!Object.hasOwn(windowOptions, view)) throw new Error('Неизвестное окно.');
  if (view !== 'tray') windows.get('tray')?.hide();
  if (payload.meeting || payload.date || payload.query !== undefined) {
    const meeting = typeof payload.meeting === 'object' ? payload.meeting?.id : payload.meeting;
    focuses.set(view, { meeting, date: payload.date, query: payload.query, token: ++focusToken });
  }
  let window = windows.get(view);
  if (window) {
    if (window.isMinimized()) window.restore();
    if (view === 'tray') positionTray(window);
    window.show();
    publish();
    window.focus();
    return window;
  }

  const [title, defaultWidth, defaultHeight, minWidth, minHeight] = windowOptions[view];
  const work = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  const bounds = disk.bounds?.[view] ?? memoWindows.get(view);
  const width = Math.min(bounds?.width ?? defaultWidth, work.width);
  const height = Math.min(bounds?.height ?? defaultHeight, work.height);
  window = new BrowserWindow({
    title, width, height, minWidth: Math.min(minWidth, work.width), minHeight: Math.min(minHeight, work.height),
    icon: iconPath, show: false, useContentSize: true, frame: view !== 'tray',
    resizable: view !== 'tray', skipTaskbar: view === 'tray', maximizable: view !== 'tray', fullscreenable: view !== 'tray',
    roundedCorners: true, alwaysOnTop: view === 'tray', autoHideMenuBar: true,
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#1f2023' : '#f6f7f9',
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true }
  });
  window.setMenu(null);
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.webContents.on('will-attach-webview', event => event.preventDefault());
  windows.set(view, window);
  window.once('ready-to-show', () => {
    if (view === 'tray') positionTray(window);
    else if (bounds && screen.getDisplayMatching(bounds).workArea.width) {
      const area = screen.getDisplayMatching(bounds).workArea;
      window.setPosition(Math.max(area.x, Math.min(bounds.x, area.x + area.width - width)),
        Math.max(area.y, Math.min(bounds.y, area.y + area.height - height)), false);
    }
    window.show();
    publish();
  });
  if (view === 'tray') window.on('blur', () => { if (!exiting) window.hide(); });
  window.on('close', () => {
    if (view === 'tray') return;
    const size = window.getNormalBounds();
    memoWindows.set(view, size);
    (disk.bounds ??= {})[view] = size;
    try { persist(); } catch { /* Window placement is optional. */ }
  });
  window.on('closed', () => windows.delete(view));
  window.loadFile(rendererPath, { query: { view } }).catch(error => {
    if (!exiting) dialog.showErrorBox('CalendarBar', error.message);
  });
  return window;
}

function positionTray(window) {
  const bounds = tray.getBounds();
  const center = bounds.width > 0 ? { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 } :
    screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(center);
  const area = display.workArea;
  const width = Math.min(windowOptions.tray[1], area.width - 8);
  const height = Math.min(trayHeight, area.height - 12);
  const x = Math.max(area.x + 4, Math.min(center.x - width / 2, area.x + area.width - width - 4));
  const y = center.y > area.y + area.height / 2 ? area.y + area.height - height - 6 : area.y + 6;
  const next = { x: Math.round(x), y: Math.round(y), width, height };
  const current = window.getBounds();
  if (Object.keys(next).some(key => next[key] !== current[key])) window.setBounds(next);
}

function openTray() {
  const window = windows.get('tray');
  if (window?.isVisible()) window.hide();
  else openWindow('tray');
}

function validURL(value) {
  const url = new URL(value);
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) {
    throw new Error('Укажите обычную ссылку HTTP или HTTPS.');
  }
  return url.href;
}

async function openLink(value, join) {
  const url = validURL(value);
  if (join) {
    const desktop = telemostDesktopURL(value);
    if (desktop) {
      try {
        await shell.openExternal(String(desktop));
        return;
      } catch {
        // The protocol is unavailable when Telemost is not installed.
      }
    }
  }
  await shell.openExternal(String(browserURL(url) ?? url));
}

function lookup(id) {
  const event = allMeetings().find(meeting => meeting.id === id) ??
    activeAccounts().flatMap(account => [...account.snoozes.map(item => item.meeting), ...account.activity.map(item => item.meeting)])
      .find(meeting => meeting.id === id);
  if (!event) throw new Error('Встреча недоступна.');
  return displayedTime(event);
}

function accountFor(login) {
  const account = disk.accounts.find(item => item.login === login);
  if (!account) throw new Error('Аккаунт не найден.');
  return account;
}

async function decrypt(account) {
  if (passwordCache.has(account.login)) return passwordCache.get(account.login);
  if (!account.password) return '';
  if (!(await safeStorage.isAsyncEncryptionAvailable())) throw new Error('Хранилище паролей Windows недоступно.');
  const secret = await safeStorage.decryptStringAsync(Buffer.from(account.password, 'base64'));
  if (!secret.result) throw new Error('Введите пароль приложения заново.');
  if (secret.shouldReEncrypt) {
    account.password = (await safeStorage.encryptStringAsync(secret.result)).toString('base64');
    persist();
  }
  passwordCache.set(account.login, secret.result);
  return secret.result;
}

function enqueue(operation) {
  const next = queue.then(operation, operation);
  queue = next.catch(() => {});
  return next;
}

function mergeCalendars(account, found) {
  const existing = new Map(account.calendars.map(calendar => [calendar.id, calendar]));
  account.calendars = found.map(calendar => {
    const old = existing.get(calendar.id);
    return { ...calendar, listed: old?.listed ?? true, visible: old?.visible ?? true,
      notify: old?.notify ?? true, color: old?.color ?? calendar.color ?? '' };
  });
  const current = new Set(found.map(item => item.id));
  for (const id of Object.keys(account.cache)) if (!current.has(id)) delete account.cache[id];
}

async function connect({ login, password, label, zone }) {
  login = String(login ?? '').trim().toLowerCase();
  zone = zone || 'Europe/Moscow';
  if (!/^[^\s:@]+@[^\s:@]+$/.test(login)) throw new Error('Укажите полный рабочий e-mail.');
  try { new Intl.DateTimeFormat('ru', { timeZone: zone }); }
  catch { throw new Error('Укажите часовой пояс, например Europe/Moscow.'); }
  if (connecting) throw new Error('Проверка подключения уже выполняется.');
  connecting = true;
  syncMessage = 'Проверяю подключение к Яндексу…';
  publish();
  try {
    await enqueue(async () => {
      const existing = disk.accounts.find(account => account.login === login);
      const account = existing ?? newProfile(login);
      const secret = password || await decrypt(account);
      if (!secret) throw new Error('Введите пароль приложения Яндекс ID типа «Календарь».');
      const found = await new YandexCalendarClient(login, secret).calendars();
      if (password) {
        if (!(await safeStorage.isAsyncEncryptionAvailable())) throw new Error('Хранилище паролей Windows недоступно.');
        account.password = (await safeStorage.encryptStringAsync(secret)).toString('base64');
      }
      if (preferences(account).zone !== zone) {
        account.cache = {};
        account.background = [];
        account.initialized = false;
      }
      if (!existing) {
        disk.accounts.push(account);
        if (!disk.primaryLogin) account.settings = { ...disk.unlinkedSettings };
      }
      account.settings.zone = zone;
      if (label !== undefined) account.label = String(label).trim().slice(0, 64);
      if (!disk.primaryLogin) disk.primaryLogin = login;
      passwordCache.set(login, secret);
      account.error = '';
      mergeCalendars(account, found);
      changed();
      syncMessage = 'Подключение проверено. Найдено календарей: ' + found.length + '.';
      if (account.active) void loadCalendar(undefined, true, [login]).catch(reportError);
    });
  } finally {
    connecting = false;
    publish();
  }
}

function reconcileCalendar(account, calendar, result, from, to) {
  const entry = (account.cache[calendar.id] ??= { meetings: {}, resources: {}, coverage: [] });
  const previous = [];
  for (const [id, meeting] of Object.entries(entry.meetings)) {
    if (intersects(meeting, from, to)) {
      previous.push(meeting);
      delete entry.meetings[id];
    }
  }
  for (const meeting of mergeCalendarMeetings(previous, result)) entry.meetings[meeting.id] = meeting;
  entry.resources = pruneCalendarResources({ ...entry.resources, ...result.resources });
  if (result.complete) entry.coverage = combineRanges([...entry.coverage, { from, to }]);
  else entry.coverage = entry.coverage.flatMap(range => {
    if (range.to <= from || range.from >= to) return [range];
    const remainder = [];
    if (range.from < from) remainder.push({ from: range.from, to: from });
    if (range.to > to) remainder.push({ from: to, to: range.to });
    return remainder;
  });
}

async function refreshAccount(account, from, to, background, force) {
  if (!account.active) return [];
  if (background) account.lastAttempt = Date.now();
  const errors = [];
  const password = await decrypt(account);
  if (!password) throw new Error('Требуется пароль приложения Яндекса.');
  const client = new YandexCalendarClient(account.login, password);
  if (background) {
    try { mergeCalendars(account, await client.calendars()); }
    catch (error) {
      if (!account.calendars.length) throw error;
      errors.push(error.message);
    }
  }
  if (!account.active || !disk.accounts.includes(account)) return [];
  const calendars = account.calendars.filter(calendar => background ? (calendar.listed || calendar.notify) : calendar.listed);
  const baselines = new Set();
  for (const calendar of calendars) {
    if (!account.active || !disk.accounts.includes(account)) return [];
    if (!force && account.cache[calendar.id]?.coverage.some(item => item.from <= from && item.to >= to)) continue;
    try {
      const result = await client.meetings(calendar, from, to, {
        cached: account.cache[calendar.id]?.resources, defaultTimeZone: preferences(account).zone
      });
      if (!account.active || !disk.accounts.includes(account)) return [];
      reconcileCalendar(account, calendar, result, from, to);
      if (!result.complete) errors.push(calendar.name + ' · часть встреч не загрузилась.');
      if (result.complete && calendar.notify) baselines.add(calendar.id);
    } catch (error) {
      errors.push(calendar.name + ' · ' + error.message);
    }
  }

  if (background) {
    const notifying = new Set(calendars.filter(calendar => calendar.notify).map(calendar => calendar.id));
    const latest = cacheMeetings(account).filter(meeting => notifying.has(meeting.calendarID) && intersects(meeting, from, to));
    const seenSeries = new Set(Object.keys(account.seenSeries));
    if (!account.initialized) account.baselineCalendars = calendars.filter(calendar =>
      calendar.notify && !baselines.has(calendar.id)).map(calendar => calendar.id);
    const current = latest.filter(meeting => baselines.has(meeting.calendarID) &&
      !account.baselineCalendars?.includes(meeting.calendarID));
    const now = Date.now();
    const changes = account.initialized ? changesBetween(account.background, current, seenSeries, now) : [];
    changes.reverse();
    account.background = latest;
    account.baselineCalendars = account.baselineCalendars?.filter(id => !baselines.has(id)) ?? [];
    account.initialized ||= baselines.size > 0;
    if (baselines.size || !errors.length) account.lastSync = now;
    for (const event of latest) account.seenSeries[event.seriesID] = now;
    account.seenSeries = Object.fromEntries(Object.entries(account.seenSeries).filter(([, at]) => now - at < 100 * DAY));
    const latestByID = new Map(latest.map(event => [event.id, event]));
    account.snoozes = account.snoozes.flatMap(item => {
      const event = latestByID.get(item.meeting.id);
      if (item.at < now || item.at >= (event ?? item.meeting).end || event?.cancelled ||
          (event && (event.start !== item.meeting.start || event.end !== item.meeting.end || event.link !== item.meeting.link)) ||
          (baselines.has(item.meeting.calendarID) && !event && intersects(item.meeting, from, to))) return [];
      return [{ ...item, meeting: event ?? item.meeting }];
    });
    account.activity = [...changes, ...account.activity].slice(0, 200);
    account.error = errors.join('\n');
    return changes;
  }
  account.error = errors.join('\n');
  return [];
}

function loadCalendar(range, force = false, selectedLogins = null) {
  const background = range === undefined || range === null;
  const currentDay = dayStart(Date.now());
  const from = background ? addDays(currentDay, -1) : dateValue(range.from);
  const to = background ? addDays(currentDay, 15) : dateValue(range.to);
  if (to <= from || to - from > 3 * 366 * DAY + MINUTE * 120) throw new Error('Выберите период не длиннее трёх лет.');
  const logins = selectedLogins ?? activeAccounts().map(account => account.login);
  if (!logins.length) return Promise.resolve();
  if (!background && !force && coverage().some(item => item.from <= from && item.to >= to)) return Promise.resolve();
  const key = JSON.stringify([background ? 'background' : from, to, logins, force]);
  if (pendingLoads.has(key)) return pendingLoads.get(key);

  syncCount++;
  syncMessage = '';
  publish();
  const load = enqueue(async () => {
    const changes = [];
    for (const login of logins) {
      const account = disk.accounts.find(item => item.login === login && item.active);
      if (!account) continue;
      try { changes.push(...await refreshAccount(account, from, to, background, force)); }
      catch (error) { account.error = error.message; }
      if (exiting) return;
      changed();
    }
    for (const change of changes) notifyChange(change);
  }).finally(() => {
    pendingLoads.delete(key);
    syncCount--;
    publish();
  });
  pendingLoads.set(key, load);
  return load;
}

function dateValue(value) {
  const date = typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? new Date(value + 'T00:00:00') : new Date(value);
  if (!value || !Number.isFinite(+date)) throw new Error('Укажите корректную дату.');
  return +date;
}

function refreshDue() {
  if (exiting) return;
  const date = new Date();
  const options = { ...preferences(primary()), ...globals() };
  const minute = date.getHours() * 60 + date.getMinutes();
  const workday = date.getDay() >= 1 && date.getDay() <= 5 &&
    minute >= options.workdayStartHour * 60 + options.workdayStartMinute &&
    minute < options.workdayEndHour * 60 + options.workdayEndMinute;
  const interval = workday ? options.workdayRefreshMinutes : options.outsideRefreshMinutes;
  if (!interval) return;
  const accounts = activeAccounts().filter(account => !account.lastAttempt ||
    account.lastAttempt > +date || +date - account.lastAttempt >= interval * MINUTE);
  if (accounts.length) void loadCalendar(undefined, true, accounts.map(account => account.login)).catch(reportError);
}

function reportError(error) {
  syncMessage = error?.message || 'Операция не выполнена.';
  publish();
}

function updateSettings({ values, login }) {
  const account = login ? accountFor(login) : primary();
  const global = disk.globals;
  const local = account?.settings ?? disk.unlinkedSettings;
  for (const key of Object.keys(profileDefaults)) {
    const value = values?.[key];
    if (value === undefined || key === 'zone') continue;
    if (typeof profileDefaults[key] === 'boolean' && typeof value === 'boolean') local[key] = value;
    if (['firstReminderMinutes', 'secondReminderMinutes'].includes(key)) local[key] = bounded(value, 1, 1440);
    if (['workdayStartHour', 'dailyOverviewHour'].includes(key)) local[key] = bounded(value, 0, 23);
    if (key === 'workdayEndHour') local[key] = bounded(value, 0, 24);
    if (['workdayStartMinute', 'workdayEndMinute', 'dailyOverviewMinute'].includes(key)) local[key] = bounded(value, 0, 59);
    if (key === 'menuCountdownWindow' && [0, 15, 30, 60, 180].includes(Number(value))) local[key] = Number(value);
    if (key === 'menuMeetingsMode' && ['currentAndUpcoming', 'allToday', 'upcomingOnly', 'currentOnly'].includes(value)) local[key] = value;
  }
  let start = (local.workdayStartHour ?? 9) * 60 + (local.workdayStartMinute ?? 0);
  let end = Math.min(1440, Math.max(1, (local.workdayEndHour ?? 18) * 60 + (local.workdayEndMinute ?? 0)));
  if (start >= end) {
    if (values.workdayStartHour !== undefined || values.workdayStartMinute !== undefined) end = Math.min(1440, start + 60);
    else start = Math.max(0, end - 60);
  }
  local.workdayStartHour = Math.floor(start / 60);
  local.workdayStartMinute = start % 60;
  local.workdayEndHour = Math.floor(end / 60);
  local.workdayEndMinute = end % 60;
  const appearance = values?.appearance ?? values?.theme;
  if (['system', 'light', 'dark'].includes(appearance)) {
    global.appearance = appearance;
    nativeTheme.themeSource = appearance;
  }
  if (typeof values?.workdayOnly === 'boolean') global.workdayOnly = values.workdayOnly;
  if (['day', 'week', 'month', 'agenda'].includes(values?.calendarView)) global.calendarView = values.calendarView;
  if ([1, 3, 5, 10, 15].includes(Number(values?.workdayRefreshMinutes))) global.workdayRefreshMinutes = Number(values.workdayRefreshMinutes);
  if ([0, 15, 30, 60, 120].includes(Number(values?.outsideRefreshMinutes))) global.outsideRefreshMinutes = Number(values.outsideRefreshMinutes);
  if (typeof values?.autoStart === 'boolean') {
    app.setLoginItemSettings({ openAtLogin: values.autoStart, args: ['--background'] });
    global.autoStart = values.autoStart;
  }
  changed();
}

function bounded(value, min, max) {
  const number = Number(value);
  if (!Number.isInteger(number)) throw new Error('Укажите целое число.');
  return Math.max(min, Math.min(max, number));
}

function saveAccount({ login, active, visible, label, primary: makePrimary }) {
  const account = accountFor(login);
  if (typeof active === 'boolean') {
    account.active = active;
    if (!active) passwordCache.delete(login);
  }
  if (typeof visible === 'boolean') account.visible = visible;
  if (label !== undefined) account.label = String(label).trim().slice(0, 64);
  if (makePrimary || (!disk.primaryLogin && account.active)) disk.primaryLogin = login;
  if (!primary()?.active && activeAccounts().length) disk.primaryLogin = activeAccounts()[0].login;
  changed();
  if (active === true) void loadCalendar(undefined, true, [login]).catch(reportError);
}

function disconnect(login) {
  const index = disk.accounts.findIndex(account => account.login === login);
  if (index < 0) throw new Error('Аккаунт не найден.');
  disk.accounts.splice(index, 1);
  passwordCache.delete(login);
  if (disk.primaryLogin === login) disk.primaryLogin = activeAccounts()[0]?.login ?? disk.accounts[0]?.login ?? '';
  changed();
}

const namedColors = new Set(['blue', 'green', 'orange', 'red', 'violet', 'cyan', 'lime', 'yellow', 'pink', 'gray']);
function colorValue(color) {
  if (!color) return '';
  if (namedColors.has(color) || /^#[a-f0-9]{6}$/i.test(color)) return color;
  throw new Error('Выберите цвет из палитры.');
}

function saveCalendar({ id, listed, visible, notify, color }) {
  const account = disk.accounts.find(item => item.calendars.some(calendar => calendar.id === id));
  if (!account) throw new Error('Календарь не найден.');
  const calendar = account.calendars.find(calendar => calendar.id === id);
  const needsRefresh = (notify === true && !calendar.notify) || (listed === true && !calendar.listed);
  if (notify === true && !calendar.notify) account.baselineCalendars = [...new Set([...(account.baselineCalendars ?? []), id])];
  if (typeof listed === 'boolean') calendar.listed = listed;
  if (typeof visible === 'boolean') calendar.visible = visible;
  if (typeof notify === 'boolean') calendar.notify = notify;
  if (color !== undefined) calendar.color = colorValue(color);
  changed();
  if (needsRefresh && account.active) void loadCalendar(undefined, true, [account.login]).catch(reportError);
}

function savePin({ id, title, url, login, remove, offset }) {
  const account = login ? accountFor(login) : null;
  const pins = account?.pins ?? disk.localPins;
  const index = pins.findIndex(pin => pin.id === id || pin.url === id);
  if (remove) {
    if (index >= 0) pins.splice(index, 1);
  } else if (offset !== undefined && index >= 0) {
    const target = Math.max(0, Math.min(pins.length - 1, index + Math.sign(Number(offset))));
    pins.splice(target, 0, pins.splice(index, 1)[0]);
  } else {
    if (!isUsableMeetingURL(url)) throw new Error('Укажите ссылку на конференцию.');
    url = validURL(url);
    const identity = telemostDesktopURL(url) ?? url;
    if (pins.some((pin, i) => i !== index && (telemostDesktopURL(pin.url) ?? pin.url) === identity)) {
      throw new Error('Эта ссылка уже закреплена.');
    }
    const record = { id: index >= 0 ? pins[index].id : randomUUID(),
      title: String(title ?? '').trim().slice(0, 256) || new URL(url).hostname, url, login: login || '' };
    if (index >= 0) pins[index] = record;
    else pins.push(record);
  }
  changed();
}

function saveReminder({ id, scope, value }) {
  const meeting = lookup(id);
  const account = accountFor(meeting.accountLogin);
  const key = scope === 'series' ? meeting.seriesID : meeting.id;
  if (value == null) delete account.reminders[key];
  else account.reminders[key] = value.muted ? { muted: true } : {
    minutes: [...new Set((value.minutes ?? []).map(value => bounded(value, 1, 1440)))].sort((a, b) => b - a)
  };
  if (scope === 'series') {
    for (const id of Object.keys(account.reminders)) {
      if (id.slice(0, id.lastIndexOf('|')) === meeting.seriesID) delete account.reminders[id];
    }
  }
  account.snoozes = account.snoozes.filter(item => item.meeting.id !== meeting.id &&
    (scope !== 'series' || item.meeting.seriesID !== meeting.seriesID));
  closeMeetingToasts(meeting.id);
  changed();
}

function saveColor({ id, scope, color }) {
  const meeting = lookup(id);
  const account = accountFor(meeting.accountLogin);
  const key = scope === 'series' ? meeting.seriesID : meeting.id;
  if (color) account.colors[key] = colorValue(color);
  else delete account.colors[key];
  changed();
}

function saveSnooze({ id, minutes, atStart, cancel }) {
  const meeting = lookup(id);
  const account = accountFor(meeting.accountLogin);
  if (!cancel) {
    const at = atStart ? meeting.start : Date.now() + bounded(minutes ?? 5, 1, 1440) * MINUTE;
    if (at <= Date.now() || at >= meeting.end || meeting.cancelled || meeting.allDay) {
      throw new Error('Выберите время до окончания встречи.');
    }
    if ((account.reminders[id] ?? account.reminders[meeting.seriesID])?.muted) account.reminders[id] = { minutes: [] };
    account.snoozes = account.snoozes.filter(item => item.meeting.id !== id);
    account.snoozes.push({ meeting, at });
  } else {
    account.snoozes = account.snoozes.filter(item => item.meeting.id !== id);
  }
  closeMeetingToasts(id);
  changed();
}

function xml(value) {
  return String(value).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/gu, '')
    .replace(/[<>&"']/g, character => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[character]);
}

function actionURL(command, id, date) {
  const url = new URL(SCHEME + '://' + command);
  if (id) url.searchParams.set('id', id);
  if (date) url.searchParams.set('date', date);
  return url.href;
}

function showToast(title, body, { meeting, reminder = false, date } = {}) {
  if (!Notification.isSupported()) return;
  const options = { title: String(title).slice(0, 256), body: String(body).slice(0, 500), icon: iconPath };
  const id = meeting?.id;
  if (process.platform === 'win32' && app.isPackaged) {
    const destination = actionURL(id ? 'meeting' : 'calendar', id, date);
    const commands = reminder ? [
      ...(meeting.link ? [['Подключиться', 'join']] : []),
      ['Через 5 минут', 'snooze'],
      ...(meeting.start > Date.now() ? [['В начале встречи', 'start']] : []),
      ['Больше не напоминать', 'mute']
    ] : [];
    const buttons = commands.map(([label, command]) => '<action content="' + xml(label) +
      '" activationType="protocol" arguments="' + xml(actionURL(command, id)) + '"/>').join('');
    options.toastXml = '<toast activationType="protocol" launch="' + xml(destination) +
      '"><visual><binding template="ToastGeneric"><text>' + xml(options.title) + '</text><text>' + xml(options.body) +
      '</text></binding></visual>' + (buttons ? '<actions>' + buttons + '</actions>' : '') + '</toast>';
  }
  const toast = new Notification(options);
  const key = randomUUID();
  alerts.set(key, { toast, id });
  toast.on('close', () => alerts.delete(key));
  toast.on('failed', (_event, error) => {
    alerts.delete(key);
    notificationStatus = 'Проверьте уведомления CalendarBar в параметрах Windows.';
    if (error) console.error('CalendarBar notification:', error);
    publish();
  });
  toast.on('click', () => {
    alerts.delete(key);
    if (id) openWindow('meeting', { meeting: id });
    else if (date) openWindow('calendar', { date });
  });
  toast.show();
  const remove = setTimeout(() => alerts.delete(key), 7 * DAY);
  remove.unref();
}

function closeMeetingToasts(id) {
  for (const [key, alert] of alerts) {
    if (alert.id !== id) continue;
    alert.toast.close();
    alerts.delete(key);
  }
}

function notifyChange(change) {
  const account = disk.accounts.find(item => item.login === change.login);
  const meeting = change.meeting;
  if (!account?.active || isDeclined(meeting, account.login)) return;
  const options = preferences(account);
  if (change.kind === 'new' ? !options.notifyNew : !options.notifyChanges) return;
  if (!change.important && !options.notifyMinorChanges) return;
  const label = { new: 'Новая встреча', changed: 'Встреча изменена', cancelled: 'Встреча отменена' }[change.kind];
  showToast(meeting.title, label + ' · ' + timeLabel(meeting.start), { meeting });
}

function timeLabel(date) {
  return new Intl.DateTimeFormat('ru-RU', { dateStyle: 'short', timeStyle: 'short' }).format(date);
}

function nextOverview(now) {
  const account = primary();
  const options = preferences(account);
  if (!account?.active || !options.dailyOverviewEnabled) return null;
  let date = new Date(now);
  date.setHours(options.dailyOverviewHour, options.dailyOverviewMinute, 0, 0);
  const day = new Date(dayStart(now)).toISOString();
  if (+date < now - 2 * MINUTE || disk.overviewDay === day) {
    date = new Date(addDays(+date, 1));
    date.setHours(options.dailyOverviewHour, options.dailyOverviewMinute, 0, 0);
  }
  return +date;
}

function overviewBody(now) {
  const start = dayStart(now);
  const end = addDays(start, 1);
  const options = preferences(primary());
  const workBoundary = (hour, minute) => new Date(start).setHours(hour, minute, 0, 0);
  const workStart = workBoundary(options.workdayStartHour, options.workdayStartMinute);
  const workEnd = workBoundary(options.workdayEndHour, options.workdayEndMinute);
  const notifyIDs = new Set(activeAccounts().flatMap(account => account.calendars.filter(item => item.notify).map(item => item.id)));
  const meetings = allMeetings().filter(event => notifyIDs.has(event.calendarID) && !event.cancelled &&
    !isDeclined(event, event.accountLogin) && intersects(event, start, end));
  const busy = meetings.filter(event => !event.allDay && !event.isFree && event.end > event.start);
  const ranges = combineRanges(busy.filter(event => event.end > workStart && event.start < workEnd)
    .map(event => ({ from: Math.max(event.start, workStart), to: Math.min(event.end, workEnd) })));
  let conflicts = 0;
  for (let i = 0; i < busy.length; i++) {
    conflicts += busy.slice(i + 1).filter(event => event.start < busy[i].end && event.end > busy[i].start).length;
  }
  return 'Встреч: ' + meetings.length + ' · занято: ' +
    Math.round(ranges.reduce((sum, range) => sum + range.to - range.from, 0) / MINUTE) + ' мин. · пересечений: ' + conflicts;
}

function scheduleNotifications() {
  clearTimeout(reminderTimer);
  if (exiting) return;
  const now = Date.now();
  const grace = Math.min(2 * MINUTE, Math.max(0, now - lastSessionReminderCheck));
  lastSessionReminderCheck = now;
  const plans = reminderPlans(activeAccounts(), now, isDeclined, grace);
  let updated = false;
  for (const plan of plans) {
    if (plan.at > now) break;
    plan.account.delivered[plan.id] = now;
    plan.account.snoozes = plan.account.snoozes.filter(item => !(item.at === plan.at && item.meeting.id === plan.meeting.id));
    for (const [id, at] of Object.entries(plan.account.delivered)) if (now - at > 16 * DAY) delete plan.account.delivered[id];
    const description = plan.minutes === null ? 'Вы просили напомнить' : 'До начала: ' + plan.minutes + ' мин.';
    showToast(plan.meeting.title, description + ' · ' + timeLabel(plan.meeting.start), { meeting: plan.meeting, reminder: true });
    updated = true;
  }
  const overview = nextOverview(now);
  if (overview !== null && overview <= now) {
    const day = dayStart(now);
    disk.overviewDay = new Date(day).toISOString();
    showToast('Ваш день в CalendarBar', overviewBody(now), { date: day });
    updated = true;
  }
  if (updated) {
    persist();
    publish();
  }
  const next = Math.min(plans.find(plan => plan.at > now)?.at ?? Infinity, nextOverview(now) ?? Infinity);
  reminderTimer = setTimeout(scheduleNotifications, Math.max(100, Math.min(MINUTE, next - now)));
}

async function handleExternalURL(input) {
  let url;
  try { url = new URL(input); } catch { return false; }
  if (url.protocol !== SCHEME + ':') return false;
  const id = url.searchParams.get('id');
  const date = Number(url.searchParams.get('date'));
  try {
    switch (url.hostname) {
      case 'calendar': openWindow('calendar', date > 0 ? { date } : {}); break;
      case 'meeting': lookup(id); openWindow('meeting', { meeting: id }); break;
      case 'join': {
        const meeting = lookup(id);
        if (!meeting.cancelled && meeting.end > Date.now() && meeting.link) await openLink(meeting.link, true);
        else openWindow('meeting', { meeting: id });
        break;
      }
      case 'snooze': saveSnooze({ id, minutes: 5 }); break;
      case 'start': saveSnooze({ id, atStart: true }); break;
      case 'mute': saveReminder({ id, scope: 'occurrence', value: { muted: true } }); break;
      default: break;
    }
  } catch {
    openWindow('calendar');
  }
  return true;
}

async function action(type, payload, fromWindow) {
  switch (type) {
    case 'open': openWindow(payload.view, payload); break;
    case 'close': fromWindow === 'tray' ? windows.get(fromWindow)?.hide() : windows.get(fromWindow)?.close(); break;
    case 'fitTray':
      if (fromWindow === 'tray') {
        trayHeight = bounded(payload.height, 132, 565);
        positionTray(windows.get('tray'));
      }
      break;
    case 'quit': app.quit(); break;
    case 'settings': updateSettings(payload); break;
    case 'clearCalendarCache':
      if (fromWindow !== 'settings') throw new Error('Очистка кэша доступна в настройках.');
      return clearCalendarCache(payload.login);
    case 'connect': await connect(payload); break;
    case 'account': saveAccount(payload); break;
    case 'disconnect': disconnect(payload.login); break;
    case 'calendar': saveCalendar(payload); break;
    case 'sync': {
      if (payload.from && payload.to) {
        await loadCalendar(payload, true);
        void loadCalendar(undefined, true).catch(reportError);
      } else await loadCalendar(undefined, true);
      break;
    }
    case 'load': await loadCalendar(payload); break;
    case 'search': {
      const from = dateValue(payload.from);
      const to = dateValue(payload.to);
      await loadCalendar(payload, Boolean(payload.force));
      const relevant = activeAccounts().filter(account => visibleAccountCalendars(account).some(calendar =>
        !account.cache[calendar.id]?.coverage.some(range => range.from <= from && range.to >= to)));
      const issues = relevant.filter(account => account.error).map(account => accountName(account) + ' · ' + account.error);
      if (issues.length) throw new Error(issues.join('\n'));
      break;
    }
    case 'join': await openLink(payload.url, true); break;
    case 'browser': await openLink(payload.url, false); break;
    case 'copyLink':
      validURL(payload.url);
      clipboard.writeText(payload.url);
      break;
    case 'create': await openLink(yandexCreateURL(dateValue(payload.start), payload.end ? dateValue(payload.end) : undefined), false); break;
    case 'edit': await openLink(yandexEventURL(lookup(payload.id)), false); break;
    case 'pin': savePin(payload); break;
    case 'hideLast': {
      const meeting = lookup(payload.id);
      accountFor(meeting.accountLogin).hiddenLast = payload.hidden ? meeting.id : '';
      changed();
      break;
    }
    case 'reminder': saveReminder(payload); break;
    case 'color': saveColor(payload); break;
    case 'markActivity':
      for (const account of activeAccounts()) for (const entry of account.activity) {
        if (!payload.id || payload.id === entry.id) entry.unread = false;
      }
      changed();
      break;
    case 'clearActivity': for (const account of activeAccounts()) account.activity = []; changed(); break;
    case 'snooze': saveSnooze(payload); break;
    case 'testNotification':
      if (!Notification.isSupported()) throw new Error('Системные уведомления недоступны.');
      setTimeout(() => showToast('CalendarBar', 'Уведомления работают.'), 3000);
      break;
    case 'notificationSettings':
      if (process.platform === 'win32') await shell.openExternal('ms-settings:notifications');
      else if (process.platform === 'darwin') await shell.openExternal('x-apple.systempreferences:com.apple.Notifications-Settings.extension');
      break;
    default: throw new Error('Неизвестное действие.');
  }
}

function validSender(event) {
  return event.senderFrame && event.senderFrame === event.sender.mainFrame &&
    event.senderFrame.url.split('?')[0] === rendererURL && viewOf(event.sender);
}

async function start() {
  disk = loadDisk(appData());
  nativeTheme.themeSource = globals().appearance;
  notificationStatus = Notification.isSupported() ? 'Системные уведомления' : 'Системные уведомления недоступны.';
  if (process.platform === 'darwin') app.dock?.hide();
  session.defaultSession.setPermissionRequestHandler((_source, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  ipcMain.handle('calendarbar:state', event => {
    if (!validSender(event)) throw new Error('Недоступно.');
    return state(viewOf(event.sender));
  });
  ipcMain.handle('calendarbar:action', async (event, type, payload = {}) => {
    if (!validSender(event)) return { ok: false, error: 'Недоступно.' };
    try {
      const result = await action(type, payload, viewOf(event.sender));
      return { ok: true, ...result };
    } catch (error) {
      return { ok: false, error: error?.message || 'Операция не выполнена.' };
    }
  });
  tray = new Tray(nativeImage.createFromPath(iconPath).resize({ width: 20, height: 20 }));
  tray.on('click', openTray);
  tray.on('right-click', () => {
    windows.get('tray')?.hide();
    tray.popUpContextMenu(Menu.buildFromTemplate([
      { label: 'Календарь', click: () => openWindow('calendar') },
      { label: 'Настройки…', click: () => openWindow('settings') },
      { label: 'Поиск встреч', click: () => openWindow('search') },
      { label: 'Закреплённые встречи…', click: () => openWindow('pinned') },
      { label: 'Изменения и напоминания', click: () => openWindow('activity') },
      { type: 'separator' },
      { label: 'Обновить', click: () => void loadCalendar(undefined, true).catch(reportError) },
      { label: 'Выход', click: () => app.quit() }
    ]));
  });
  const startURLs = process.argv.filter(arg => arg.startsWith(SCHEME + ':'));
  if (startURLs.length) await handleExternalURL(startURLs[0]);
  else if (!process.argv.includes('--background')) {
    const preview = process.argv.find(arg => arg.startsWith('--open='));
    const view = preview?.slice('--open='.length);
    openWindow(Object.hasOwn(windowOptions, view) ? view : disk.accounts.length ? 'calendar' : 'settings');
  }
  updateTray();
  scheduleNotifications();
  refreshDue();
  refreshTimer = setInterval(refreshDue, 15_000);
  setInterval(updateTray, 15_000).unref();
  powerMonitor.on('resume', () => {
    scheduleNotifications();
    refreshDue();
    publish();
  });
  nativeTheme.on('updated', publish);
  return true;
}

app.setName('CalendarBar');
if (!app.isPackaged && process.platform === 'darwin') {
  const previewData = process.argv.find(arg => arg.startsWith('--preview-data='));
  app.setPath('userData', previewData?.slice('--preview-data='.length) ||
    path.join(app.getPath('appData'), 'CalendarBar Windows Preview'));
}
app.setAppUserModelId(ID);
if (process.platform === 'win32') app.setToastActivatorCLSID(TOAST_ACTIVATOR);
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_event, args) => {
    if (!disk) return;
    const url = args.find(arg => arg.startsWith(SCHEME + ':'));
    if (url) void handleExternalURL(url).catch(reportError);
    else if (!args.includes('--background')) {
      const preview = args.find(arg => arg.startsWith('--open='));
      const view = preview?.slice('--open='.length);
      openWindow(Object.hasOwn(windowOptions, view) ? view : disk.accounts.length ? 'calendar' : 'settings');
    }
  });
  app.on('window-all-closed', () => {});
  app.on('before-quit', () => {
    exiting = true;
    clearInterval(refreshTimer);
    clearTimeout(reminderTimer);
  });
  void app.whenReady().then(start).catch(error => {
    dialog.showErrorBox('CalendarBar', error?.message || 'Не удалось запустить приложение.');
    app.exit(1);
  });
}
