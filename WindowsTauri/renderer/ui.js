'use strict';

const api = window.calendarBar;
const app = document.querySelector('#app');
const dialog = document.querySelector('#dialog');
const contextMenu = document.querySelector('#context');
const params = new URLSearchParams(location.search);
const view = params.get('view') || 'calendar';
const minute = 60_000;
const day = 86_400_000;
const modes = { day: 'День', week: 'Неделя', month: 'Месяц', agenda: 'Расписание' };
const filters = { day: 'Фильтр дня', week: 'Фильтр недели', month: 'Фильтр месяца', agenda: 'Фильтр расписания' };
const pages = { accounts: ['Подключение', 'person'], notifications: ['Уведомления', 'bell'],
    appearance: ['Вид', 'calendar'], general: ['Основные', 'gear'], cache: ['Кэш календаря', 'drive'] };
const iconPaths = {
    calendar: '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M7 3v4m10-4v4M3 10h18m-13 4h1m4 0h1m4 0h.01M8 17h1m4 0h1"/>',
    sidebar: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 4v16m-3-12h.01M6 11h.01"/>',
    inspector: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M15 4v16m3-12h.01M18 11h.01"/>',
    left: '<path d="m14.5 6-6 6 6 6"/>',
    right: '<path d="m9.5 6 6 6-6 6"/>',
    down: '<path d="m6 9 6 6 6-6"/>',
    up: '<path d="m6 15 6-6 6 6"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    gear: '<path d="m10.4 3-.6 2.1-1.7.9-2.1-.6-1.6 2.7 1.5 1.6v1.9l-1.5 1.6 1.6 2.7 2.1-.6 1.7.9.6 2.1h3.2l.6-2.1 1.7-.9 2.1.6 1.6-2.7-1.5-1.6V9.7l1.5-1.6L18 5.4l-2.1.6-1.7-.9-.6-2.1z" transform="translate(0 1.3)"/><circle cx="12" cy="12" r="2.6"/>',
    refresh: '<path d="M20 4v5h-5M20 9a8 8 0 1 0 .1 5"/>',
    search: '<circle cx="10.5" cy="10.5" r="6"/><path d="m15 15 4.5 4.5"/>',
    out: '<path d="M13 4h7v7m0-7-9 9m8 1v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h4"/>',
    link: '<path d="m10 13 4-4m-6 6-1 1a3.5 3.5 0 0 1-5-5l4-4a3.5 3.5 0 0 1 5 0m2 2 1-1a3.5 3.5 0 0 1 5 5l-4 4a3.5 3.5 0 0 1-5 0" transform="translate(1.5 0.7)"/>',
    pin: '<path d="m11 4 9 9-2.5.8-2.3 2.3-.7 3.4-9.9-9.9 3.4-.7 2.3-2.3L11 4zm-1.8 10.8L4 20"/>',
    bell: '<path d="M18 9a6 6 0 1 0-12 0c0 4-1.5 5-2 6.5h16c-.5-1.5-2-2.5-2-6.5zm-8 10a2 2 0 0 0 4 0"/>',
    clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3 2"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19m0-14-1.5 1.5m-11 11L5 19"/>',
    video: '<rect x="3" y="6" width="12" height="12" rx="2.5"/><path d="m15 10 5-3v10l-5-3"/>',
    person: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="10" r="2.7"/><path d="M6 18c.8-2.8 3-4 6-4s5.2 1.2 6 4"/>',
    people: '<circle cx="9.5" cy="8.5" r="3"/><path d="M3 19v-1a4 4 0 0 1 4-4h5a4 4 0 0 1 4 4v1m.5-13.5a3 3 0 0 1 0 6m4.5 7V18a4 4 0 0 0-3-3.8"/>',
    options: '<path d="M3 7h3m4 0h11M3 17h11m4 0h3"/><circle cx="8" cy="7" r="2"/><circle cx="16" cy="17" r="2"/>',
    more: '<circle cx="5" cy="12" r="1.35" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.35" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.35" fill="currentColor" stroke="none"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5m0-8h.01"/>',
    drive: '<path d="m3.5 14 2.6-7.5A2 2 0 0 1 8 5h8a2 2 0 0 1 1.9 1.5l2.6 7.5"/><rect x="3" y="13" width="18" height="6" rx="2"/><path d="M7 16h.01M10.5 16h.01"/>',
    warning: '<path d="M10.2 4.6a2 2 0 0 1 3.6 0l7 12.6A2 2 0 0 1 19 20H5a2 2 0 0 1-1.8-2.8zM12 9v4m0 3h.01"/>',
    check: '<path d="m5 12 4.5 4.5L19 7"/>',
    location: '<path d="M19 10c0 5-7 10-7 10S5 15 5 10a7 7 0 0 1 14 0z"/><circle cx="12" cy="10" r="2.5"/>',
    repeat: '<path d="m16 3 3 3-3 3m3-3H8a4 4 0 0 0-4 4m4 11-3-3 3-3m-3 3h11a4 4 0 0 0 4-4"/>',
    color: '<path d="M12 3a9 9 0 0 0 0 18h1a1.7 1.7 0 0 0 1.2-2.9 1.8 1.8 0 0 1 1.3-3.1H18a3 3 0 0 0 3-3.2C21 7 17 3 12 3zM7 12h.01M8.5 8.4h.01M12 7h.01M15.7 8.4h.01" stroke-width="2"/>',
    history: '<path d="M3.5 6v5h5M4 10.5a8.5 8.5 0 1 1 .9 5.9M12 7v5l3.5 2"/>',
    restore: '<path d="m9 6-5 5 5 5m-5-5h10a5 5 0 0 1 0 10"/>',
    question: '<path d="M8.8 8a3.3 3.3 0 1 1 4.7 3c-1.1.6-1.5 1.2-1.5 2.5m0 3.5h.01"/>',
    tentative: '<circle cx="12" cy="12" r="8"/><path d="M12 4v16a8 8 0 0 0 0-16z" fill="currentColor" stroke="none"/>',
    organizer: '<path d="m12 3 7 9-7 9-7-9z" fill="currentColor" stroke="none"/>'
};
const statusInfo = {
    accepted: ['check', 'Принято'], needsAction: ['question', 'Ожидает ответа'], tentative: ['tentative', 'Возможно'],
    declined: ['close', 'Отклонено'], organizer: ['organizer', 'Организатор'], unknown: ['', 'Статус ответа неизвестен']
};
const palette = ['#1ACB64', '#08C4A9', '#24A8C5', '#378BE7', '#7D6AFF', '#A95FD3', '#E1518F',
    '#DF4D59', '#E87C22', '#CD9E11', '#8EA531', '#63708A', '#50555E', '#79534B'];
const formatterCache = new Map();
const weekday = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
const initial = Date.now();
let state = { accounts: [], meetings: [], pins: [], activity: [], snoozes: [], coverage: [], settings: {} };
let mode = 'week';
let anchor = Number(localStorage.getItem('calendarAnchor')) || initial;
let selectedDay = anchor;
let selectedId = '';
let searchId = '';
let standaloneId = '';
let focusToken;
let searchQuery = params.get('query') || '';
let searchFrom = startOfDay(addMonths(initial, -3));
let searchTo = addDays(startOfDay(addMonths(initial, 3)), 1);
let highlighted = -1;
let filter = '';
let page = 'accounts';
let cacheFeedback = '';
let inspector = false;
let compactSidebar = false;
let sidebar = localStorage.getItem('calendarSidebar') !== 'false';
let showDeclined = localStorage.getItem('showDeclined') === 'true';
let popover = '';
let miniMonth = anchor;
let rangeKey = '';
let searchLoading = false;
let searchError = '';
let scrollIntent = view === 'calendar' ? 'period' : '';
let pinLogin;
let pinEdit;
let toastTimer;
let trayObserver;
let lastTrayHeight;
let initialDraft = {};
let lastCompact = matchMedia('(max-width:1199px)').matches;
const collapsed = new Set();
const disclosure = new Map();

function html(value = '') {
    return String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]);
}

function icon(name) {
    if (!Object.hasOwn(iconPaths, name)) return '';
    return '<svg class="symbol" aria-hidden="true" focusable="false" viewBox="0 0 24 24" fill="none" ' +
        'stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' +
        iconPaths[name] + '</svg>';
}

function encoded(value) {
    return html(JSON.stringify(value ?? {}));
}

function button(label, action, payload = {}, options = {}) {
    const { glyph, only, className = '', disabled = false, pressed, hint = label } = options;
    return '<button type="button" data-action="' + html(action) + '" data-payload="' + encoded(payload) + '" class="' +
        html(className + (only ? ' icon' : '')) + '" title="' + html(hint) + '"' +
        (only ? ' aria-label="' + html(label) + '"' : '') +
        (pressed == null ? '' : ' aria-pressed="' + pressed + '"') +
        (disabled ? ' disabled' : '') + '>' + icon(glyph) + (only ? '' : '<span class="button-label">' + html(label) + '</span>') + '</button>';
}

function iconButton(label, glyph, action, payload, options) {
    return button(label, action, payload, { glyph, only: true, className: 'plain', ...options });
}

function checkbox(label, action, payload, checked, options = {}) {
    return '<input type="checkbox" data-change="' + html(action) + '" data-payload="' + encoded(payload) +
        '" aria-label="' + html(label) + '"' + (checked ? ' checked' : '') + (options.disabled ? ' disabled' : '') +
        (options.toggle ? ' class="switch"' : '') + '>';
}

function select(label, items, value, action, payload = {}, className = '') {
    return '<select aria-label="' + html(label) + '" data-change="' + action + '" data-payload="' + encoded(payload) + '" class="' +
        html(className) + '">' + items.map(([key, text]) => '<option value="' + html(key) + '"' + (String(key) === String(value) ? ' selected' : '') + '>' +
        html(text) + '</option>').join('') + '</select>';
}

function currentTime() {
    return Date.now();
}

function startOfDay(time) {
    const date = new Date(time);
    date.setHours(0, 0, 0, 0);
    return +date;
}

function addDays(time, offset) {
    const date = new Date(time);
    date.setDate(date.getDate() + offset);
    return +date;
}

function addMonths(time, offset) {
    const date = new Date(time);
    const number = date.getDate();
    date.setDate(1);
    date.setMonth(date.getMonth() + offset);
    const limit = new Date(date.getFullYear(), date.getMonth() + 1, 0).getDate();
    date.setDate(Math.min(limit, number));
    return +date;
}

function civilDate(time) {
    const date = new Date(time);
    return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0')].join('-');
}

function parseCivil(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value ?? '')) return NaN;
    const [year, month, date] = value.split('-').map(Number);
    return +new Date(year, month - 1, date);
}

function startOfMonth(time) {
    const date = new Date(time);
    return +new Date(date.getFullYear(), date.getMonth(), 1);
}

function daysFrom(time, count) {
    return Array.from({ length: count }, (_, i) => addDays(time, i));
}

function weekDays(time) {
    const start = startOfDay(time);
    return daysFrom(addDays(start, -((new Date(start).getDay() + 6) % 7)), 7);
}

function monthDays(time) {
    return daysFrom(weekDays(startOfMonth(time))[0], 42);
}

function periodDays() {
    if (mode === 'day') return [startOfDay(anchor)];
    if (mode === 'week') return weekDays(anchor);
    if (mode === 'month') return monthDays(anchor);
    const from = startOfMonth(anchor);
    const length = new Date(new Date(from).getFullYear(), new Date(from).getMonth() + 1, 0).getDate();
    return daysFrom(from, length);
}

function format(value, style) {
    if (!Number.isFinite(+value)) return '';
    const styles = {
        month: { month: 'long', year: 'numeric' }, day: { day: 'numeric', month: 'long', year: 'numeric' },
        shortDay: { day: 'numeric', month: 'short' }, longDay: { day: 'numeric', month: 'long' },
        weekday: { weekday: 'long', day: 'numeric', month: 'long' }, time: { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' },
        dateTime: { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }
    };
    if (!formatterCache.has(style)) formatterCache.set(style, new Intl.DateTimeFormat('ru-RU', styles[style]));
    return formatterCache.get(style).format(value).replace(/ г\.$/, '');
}

function capitalize(value) {
    return value.charAt(0).toUpperCase() + value.slice(1);
}

function timeLabel(meeting) {
    if (meeting.allDay) return 'Весь день';
    return format(meeting.start, 'time') + '–' + format(meeting.end, startOfDay(meeting.start) === startOfDay(meeting.end) ? 'time' : 'dateTime');
}

function relativeDay(time) {
    const today = startOfDay(currentTime());
    const date = startOfDay(time);
    if (date === today) return 'Сегодня';
    if (date === addDays(today, 1)) return 'Завтра';
    if (date === addDays(today, -1)) return 'Вчера';
    return capitalize(format(date, 'weekday'));
}

function timelineMinute(time) {
    const date = new Date(time);
    return date.getHours() * 60 + date.getMinutes() + date.getSeconds() / 60;
}

function atMinute(time, offset) {
    const date = new Date(time);
    return +new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, offset);
}

function defaultStart(time) {
    return startOfDay(time) === startOfDay(currentTime()) ? Math.ceil(currentTime() / (15 * minute)) * 15 * minute : atMinute(time, 9 * 60);
}

function clock(minutes) {
    return String(Math.floor(minutes / 60)).padStart(2, '0') + ':' + String(Math.floor(minutes % 60)).padStart(2, '0');
}

function duration(minutes) {
    const hours = Math.floor(minutes / 60);
    const rest = Math.floor(minutes % 60);
    return [hours ? hours + ' ч' : '', rest ? rest + ' мин' : ''].filter(Boolean).join(' ') || 'менее минуты';
}

function profile(login = state.primaryLogin) {
    return state.accounts.find(account => account.login === login);
}

function accountName(login) {
    return profile(login)?.label || login;
}

function accountSettings(login) {
    return { ...state.settings, ...profile(login)?.settings };
}

function activeAccounts() {
    return state.accounts.filter(account => account.active !== false);
}

function calendarOf(id) {
    return state.accounts.flatMap(account => account.calendars || []).find(calendar => calendar.id === id);
}

function tint(meeting) {
    return hex(state.colors?.[meeting.id] ?? state.colors?.[meeting.seriesID] ?? meeting.color ?? calendarOf(meeting.calendarID)?.color);
}

function hex(value, fallback = '#1ACB64') {
    return /^#[\da-f]{6}$/i.test(value ?? '') ? value : fallback;
}

function activeVisibleMeetings() {
    const ids = new Set(activeAccounts().filter(account => account.visible !== false)
        .flatMap(account => (account.calendars || []).filter(calendar => calendar.listed !== false && calendar.visible !== false).map(calendar => calendar.id)));
    return state.meetings.filter(meeting => !meeting.cancelled && ids.has(meeting.calendarID))
        .map(displayedMeeting).sort((first, second) => first.start - second.start || String(first.id).localeCompare(String(second.id)));
}

function displayedMeeting(meeting) {
    if (!meeting) return null;
    if (meeting.allDay && meeting.allDayDates?.start && meeting.allDayDates?.end) {
        return { ...meeting, start: parseCivil(meeting.allDayDates.start), end: parseCivil(meeting.allDayDates.end) };
    }
    return { ...meeting, start: +new Date(meeting.start), end: +new Date(meeting.end) };
}

function findMeeting(id) {
    if (!id) return null;
    return displayedMeeting(state.meetings.find(meeting => meeting.id === id) ||
        (state.focusMeeting?.id === id ? state.focusMeeting : null) ||
        state.activity.find(item => item.meeting?.id === id)?.meeting ||
        state.snoozes.find(item => item.meeting?.id === id)?.meeting);
}

function onDay(meetings, time) {
    const from = startOfDay(time);
    return meetings.filter(meeting => intersects(meeting, from, addDays(from, 1)))
        .sort((left, right) => Number(right.allDay) - Number(left.allDay) || left.start - right.start);
}

function intersects(meeting, from, to) {
    return meeting.start < to && (meeting.end > from || (meeting.start === meeting.end && meeting.start >= from));
}

function status(meeting) {
    const login = (meeting.accountLogin || state.primaryLogin || '').toLowerCase();
    if (!login) return 'unknown';
    if ((meeting.organizer || '').toLowerCase() === login) return 'organizer';
    const response = meeting.attendees?.find(attendee => attendee.email?.toLowerCase() === login)?.response?.toUpperCase();
    return ({ ACCEPTED: 'accepted', 'NEEDS-ACTION': 'needsAction', TENTATIVE: 'tentative', DECLINED: 'declined' })[response] || 'unknown';
}

function statusLabel(meeting, compact = false, showUnknown = false) {
    const value = status(meeting);
    if (value === 'unknown' && (!showUnknown || compact)) return '';
    const [symbol, text] = statusInfo[value];
    return '<span class="status-icon ' + value + '" title="' + text + '">' + (icon(symbol) + (compact ? '' : html(text))) + '</span>';
}

function matches(meeting, query) {
    const haystack = [meeting.title, meeting.calendarName, meeting.details, meeting.location, meeting.organizer,
        accountName(meeting.accountLogin), ...(meeting.attendees || []).flatMap(person => [person.email, person.name])].filter(Boolean).join(' ').toLocaleLowerCase('ru');
    return query.toLocaleLowerCase('ru').trim().split(/\s+/).every(word => haystack.includes(word));
}

function filteredMeetings(meetings) {
    return meetings.filter(meeting => (showDeclined || status(meeting) !== 'declined') && matches(meeting, filter));
}

function periodTitle(dates) {
    if (mode === 'day') return format(anchor, 'day');
    if (mode !== 'week') return capitalize(format(anchor, 'month'));
    const first = new Date(dates[0]);
    const last = new Date(dates.at(-1));
    const sameYear = first.getFullYear() === last.getFullYear();
    return (sameYear && first.getMonth() === last.getMonth() ? first.getDate() :
        format(+first, sameYear ? 'shortDay' : 'day')) + '–' + format(+last, 'day');
}

function searchInput(id, placeholder, value, action) {
    return '<input id="' + id + '" class="filter" type="text" autocomplete="off" spellcheck="false" placeholder="' +
        html(placeholder) + '" aria-label="' + html(placeholder) + '" data-input="' + action + '" value="' + html(value) + '">';
}

function toolbar(dates) {
    return '<header class="toolbar"><div class="row navigation">' +
        iconButton('Показать или скрыть календари', 'sidebar', 'sidebar') +
        button('Сегодня', 'navigate', { date: currentTime() }) +
        iconButton('Предыдущий период', 'left', 'move', { offset: -1 }) +
        iconButton('Следующий период', 'right', 'move', { offset: 1 }) +
        '<button class="period plain" data-action="popover" data-payload="' + encoded({ name: 'date' }) + '" title="Выбрать дату">' +
        html(periodTitle(dates)) + icon('down') + '</button></div>' +
        '<div class="segments" role="group" aria-label="Вид календаря">' +
        Object.entries(modes).map(([key, text]) => button(text, 'mode', { mode: key }, { pressed: mode === key })).join('') +
        '</div>' + select('Вид календаря', Object.entries(modes), mode, 'mode', {}, 'mode-select') + '<span class="spacer"></span>' +
        '<div class="row">' + searchInput('period-filter', filters[mode], filter, 'filter') +
        '<button type="button" title="Поиск встреч по видимым календарям · Ctrl+F" aria-label="Поиск" data-action="openSearch">' +
        icon('search') + '<span class="search-name">Поиск</span></button></div><div class="row">' +
        iconButton('Показать или скрыть подробности', 'inspector', 'inspector') +
        iconButton('Параметры отображения', 'options', 'popover', { name: 'options' }) +
        button('Создать', 'createEvent', { start: defaultStart(selectedDay) }, { glyph: 'plus', className: 'primary' }) + '</div>' +
        (popover === 'date' ? miniCalendar() : '') +
        (popover === 'options' ? '<div class="popover options-pop stack"><label class="row">' +
        checkbox('Показывать отклонённые встречи', 'declined', {}, showDeclined) + 'Показывать отклонённые встречи</label>' +
        (mode === 'day' || mode === 'week' ? '<label class="row">' + checkbox(workdayOnlyTitle, 'setting', { key: 'workdayOnly' },
            state.settings.workdayOnly !== false) + html(workdayOnlyTitle) + '</label>' : '') + '</div>' : '') + '</header>';
}

function miniCalendar() {
    return '<div class="popover date-pop"><div class="row">' +
        iconButton('Предыдущий месяц', 'left', 'miniMove', { offset: -1 }) +
        '<strong class="spacer" style="text-align:center">' + html(capitalize(format(miniMonth, 'month'))) + '</strong>' +
        iconButton('Следующий месяц', 'right', 'miniMove', { offset: 1 }) +
        '</div><div class="mini-days">' + weekday.map(text => '<span class="note">' + text + '</span>').join('') +
        monthDays(miniMonth).map(date => '<button class="plain' + (startOfDay(selectedDay) === date ? ' chosen' : '') +
            (startOfDay(currentTime()) === date ? ' today' : '') + (startOfMonth(date) !== startOfMonth(miniMonth) ? ' muted' : '') +
            '" aria-current="' + (startOfDay(selectedDay) === date) + '" aria-label="' + html(format(date, 'day')) +
            '" data-action="navigate" data-payload="' + encoded({ date, summary: true }) + '">' + new Date(date).getDate() + '</button>').join('') + '</div></div>';
}

function calendarSidebar() {
    const shown = activeAccounts();
    if (!sidebar && !compactSidebar) return '';
    return '<aside class="sidebar' + (compactSidebar ? ' compact-open' : '') + '"><h3 class="muted">Календари</h3>' +
        '<div class="groups scroll" data-scroll="calendars">' + (shown.length ? shown.map(account => {
            const { login } = account;
            const isCollapsed = collapsed.has(login);
            const calendars = (account.calendars || []).filter(calendar => calendar.listed !== false);
            return '<div class="stack"><div class="row">' + iconButton(isCollapsed ? 'Развернуть' : 'Свернуть',
                isCollapsed ? 'right' : 'down', 'collapseAccount', { login }) +
                '<label title="' + html(login) + '">' + checkbox(accountName(login), 'account', { login, key: 'visible' }, account.visible !== false) +
                '<span class="strong ellipsis">' + html(accountName(login)) + '</span></label></div>' +
                (!isCollapsed ? calendars.map(calendar => '<div class="row cal-row">' +
                '<button type="button" class="dot" style="--tint:' + hex(calendar.color) + '" aria-label="Цвет календаря" title="Цвет календаря" data-action="calendarColor" data-payload="' +
                encoded({ id: calendar.id }) + '"></button><label title="' + html(calendar.name) + '">' +
                checkbox(calendar.name, 'calendar', { id: calendar.id, key: 'visible' }, calendar.visible !== false, { disabled: account.visible === false }) +
                '<span class="ellipsis">' + html(calendar.name) + '</span></label></div>').join('') ||
                '<span class="note" style="padding-left:14px">Нет календарей в списке</span>' : '') + '</div>';
        }).join('') : '<span class="muted">Включите аккаунт в настройках.</span>') + '</div>' +
        '<div>' + button('Яндекс Календарь', 'browser', { url: 'https://calendar.yandex.ru/' }, { glyph: 'out', className: 'plain' }) + '</div></aside>';
}

const workdayOnlyTitle = 'Скрывать пустые часы вне рабочего времени';

function workdayMinutes() {
    const settings = state.settings;
    const start = (settings.workdayStartHour ?? 9) * 60 + (settings.workdayStartMinute ?? 0);
    const end = (settings.workdayEndHour ?? 18) * 60 + (settings.workdayEndMinute ?? 0);
    return [start, Math.min(1440, Math.max(start + 1, end))];
}

function coverageIncludes(from, to) {
    return (state.coverage || []).some(range => +new Date(range.from) <= from && +new Date(range.to) >= to);
}

function canShowFree(from, to) {
    return coverageIncludes(from, to) && activeAccounts().some(account => account.visible !== false &&
        account.calendars?.some(calendar => calendar.listed !== false && calendar.visible !== false));
}

function freeSlots(date, meetings) {
    const current = currentTime();
    if (!canShowFree(date, addDays(date, 1)) || date < startOfDay(current) || [0, 6].includes(new Date(date).getDay())) return [];
    const [first, last] = workdayMinutes();
    const start = Math.max(atMinute(date, first), date === startOfDay(current) ? current : date);
    const end = atMinute(date, last);
    let cursor = start;
    const slots = [];
    for (const meeting of meetings.filter(meeting => !meeting.allDay && !meeting.isFree && status(meeting) !== 'declined' &&
        meeting.end > meeting.start && intersects(meeting, start, end)).sort((left, right) => left.start - right.start)) {
        if (meeting.start - cursor >= 30 * minute) slots.push([cursor, meeting.start]);
        cursor = Math.max(cursor, meeting.end);
    }
    if (end - cursor >= 30 * minute) slots.push([cursor, end]);
    return slots;
}

function clippedMinutes(meeting, date) {
    return [meeting.start < date ? 0 : timelineMinute(meeting.start), meeting.end >= addDays(date, 1) ? 1440 : timelineMinute(meeting.end)];
}

function timeline(dates, filtered, visible) {
    const today = startOfDay(currentTime());
    const items = dates.map(date => onDay(filtered, date));
    const compact = state.settings.workdayOnly !== false;
    let [first, last] = compact ? workdayMinutes() : [0, 1440];
    dates.forEach((date, i) => {
        for (const meeting of items[i].filter(meeting => !meeting.allDay)) {
            const [from, to] = clippedMinutes(meeting, date);
            first = Math.min(first, Math.floor(from));
            last = Math.max(last, Math.ceil(to));
        }
    });
    const labels = [first];
    for (let value = Math.floor(first / 60) * 60 + 60; value < last; value += 60) labels.push(value);
    if (labels.at(-1) < last) labels.push(last);
    const top = value => Math.max(0, (value - first) * 52 / 60);
    const visibleLabels = labels.filter(value => value === first || (top(value) >= 16 &&
        (value === last || top(last) - top(value) >= 16)));
    const timezone = new Intl.DateTimeFormat('en', { timeZoneName: 'shortOffset' }).formatToParts(dates[0]).find(part => part.type === 'timeZoneName')?.value || 'GMT';
    const css = ' style="--columns:' + dates.length + '"';
    return '<div class="week-grid week-head"' + css + '><div class="timezone">' + html(timezone) + '</div>' +
        dates.map(date => '<button type="button" data-action="daySummary" data-payload="' + encoded({ date }) + '" aria-pressed="' +
        (startOfDay(selectedDay) === date) + '" aria-label="' + html(format(date, 'weekday')) + '"><span class="day-label">' +
        weekday[(new Date(date).getDay() + 6) % 7] + '</span><span class="date-number' + (date === today ? ' today' : '') +
        '">' + new Date(date).getDate() + '</span></button>').join('') + '</div><div class="week-grid all-day"' + css +
        '><div class="time-label">Весь день</div>' + dates.map((date, i) => '<div class="all-day-cell">' +
        items[i].filter(meeting => meeting.allDay).map(meeting => eventChip(meeting, date)).join('') + '</div>').join('') + '</div>' +
        '<div class="timeline-scroll" data-scroll="timeline" data-minute="' + first + '"><div class="week-grid"' + css +
        '><div class="time-ruler" style="height:' + (top(last) + 17) + 'px">' +
        visibleLabels.map(value => '<span class="tick" style="top:' + top(value) + 'px">' + clock(value) + '</span>').join('') + '</div>' +
        dates.map((date, i) => {
            const weekend = [0, 6].includes(new Date(date).getDay());
            const minutesNow = timelineMinute(currentTime());
            return '<div class="time-column' + (date === today ? ' today' : weekend ? ' weekend' : '') +
                '" data-date="' + date + '" data-minute="' + first + '">' +
                labels.map(value => '<span class="tick" style="top:' + top(value) + 'px"></span>').join('') +
                freeSlots(date, visible).map(([start, end]) => '<button type="button" class="free-slot" title="Запланировать встречу в свободное окно" data-action="freeSlot" data-payload="' +
                    encoded({ start, end }) + '" style="top:' + top(timelineMinute(start)) + 'px;height:' +
                    (top(end === addDays(date, 1) ? 1440 : timelineMinute(end)) - top(timelineMinute(start))) + 'px">Свободно · ' +
                    duration((end - start) / minute) + ' ↗</button>').join('') +
                placements(items[i].filter(meeting => !meeting.allDay), date).map(({ meeting, start, end, lane, lanes }) =>
                    eventChip(meeting, date, { top: top(start), height: top(end) - top(start), lane, lanes })).join('') +
                (date === today && minutesNow >= first && minutesNow <= last ? '<span class="now-line" style="top:' + top(minutesNow) + 'px"></span>' : '') +
                '</div>';
        }).join('') + '</div></div>';
}

function placements(meetings, date) {
    const blocks = meetings.map(meeting => {
        const [start, end] = clippedMinutes(meeting, date);
        return { meeting, start, end: Math.max(start, end) };
    }).sort((first, second) => first.start - second.start || second.end - first.end);
    const result = [];
    let lanes = [];
    let group = [];
    let groupEnd = -1;
    function flush() {
        for (const block of group) result.push({ ...block, lanes: lanes.length });
        group = [];
        lanes = [];
    }
    for (const block of blocks) {
        if (block.start >= groupEnd) {
            flush();
            groupEnd = -1;
        }
        let lane = lanes.findIndex(end => end <= block.start);
        if (lane < 0) lane = lanes.length;
        lanes[lane] = Math.max(block.end, block.start + 1);
        group.push({ ...block, lane });
        groupEnd = Math.max(groupEnd, lanes[lane]);
    }
    flush();
    return result;
}

function eventChip(meeting, date, position) {
    const classes = ['event-chip', position ? 'timed' : 'small', selectedId === meeting.id ? 'selected' : '', status(meeting) === 'declined' ? 'declined' : ''].join(' ');
    const geometry = position ? ';top:' + position.top + 'px;height:' + Math.max(14, position.height - 1) + 'px;left:calc(' +
        (100 * position.lane / position.lanes) + '% + 2px);width:calc(' + (100 / position.lanes) + '% - 4px)' : '';
    return '<button class="' + classes + '" type="button" style="--tint:' + tint(meeting) + geometry +
        '" data-meeting="' + html(meeting.id) + '" data-action="selectMeeting" data-payload="' + encoded({ id: meeting.id, date }) +
        '" title="' + html(timeLabel(meeting) + ' · ' + meeting.title) + '"><span class="event-title">' +
        statusLabel(meeting, true) + (!position && !meeting.allDay ? html(format(meeting.start, 'time')) + ' ' : '') +
        '<span class="ellipsis">' + html(meeting.title) + '</span></span>' +
        (position && position.height > 34 ? '<span class="event-time">' + html(timeLabel(meeting)) + '</span>' : '') + '</button>';
}

function monthGrid(dates, meetings) {
    const today = startOfDay(currentTime());
    const maxEvents = innerHeight < 715 ? 2 : 3;
    return '<div class="month scroll" data-scroll="month"><div class="month-weekdays">' +
        weekday.map(label => '<span>' + label + '</span>').join('') + '</div><div class="month-cells">' +
        dates.map(date => {
            const events = onDay(meetings, date);
            return '<div class="month-day' + (startOfMonth(date) !== startOfMonth(anchor) ? ' outside' : '') +
                (date === startOfDay(selectedDay) ? ' selected' : '') + '"><div class="row"><button type="button" class="date-number' +
                (date === today ? ' today' : '') + '" data-action="daySummary" data-payload="' + encoded({ date, navigate: startOfMonth(date) !== startOfMonth(anchor) }) +
                '" aria-label="' + html(format(date, 'weekday')) + '">' + new Date(date).getDate() + '</button><span class="spacer"></span>' +
                iconButton('Создать событие', 'plus', 'createEvent', { start: defaultStart(date) }, { className: 'plain add' }) + '</div>' +
                events.slice(0, maxEvents).map(meeting => eventChip(meeting, date)).join('') +
                (events.length > maxEvents ? button('Ещё ' + (events.length - maxEvents), 'daySummary', { date }, { className: 'plain' }) : '') + '</div>';
        }).join('') + '</div></div>';
}

function resultRow(meeting, date, options = {}) {
    const { search = false, highlight = false, action = 'selectMeeting' } = options;
    return '<div class="result-row' + (highlight ? ' highlighted' : '') + '" data-meeting="' + html(meeting.id) +
        '"><button type="button" class="plain" data-action="' + action + '" data-payload="' + encoded({ id: meeting.id, date }) + '">' +
        '<span class="event-clock">' + html(meeting.allDay ? 'Весь день' : format(meeting.start, 'time')) + '</span>' +
        '<span class="tint-dot" style="--tint:' + tint(meeting) + '"></span><span class="stack" style="gap:2px"><strong>' +
        html(meeting.title) + '</strong><span class="note">' + html([meeting.calendarName || calendarOf(meeting.calendarID)?.name, search && meeting.location].filter(Boolean).join(' · ')) +
        '</span>' + statusLabel(meeting) + '</span></button>' +
        (search ? button('В календаре', 'focusCalendar', { id: meeting.id }, { glyph: 'calendar' }) : '') + '</div>';
}

function scheduleGrid(dates, meetings) {
    return '<div class="schedule scroll" data-scroll="schedule">' +
        button('Предыдущий месяц', 'move', { offset: -1 }, { glyph: 'left', className: 'plain' }) +
        dates.map(date => {
            const events = onDay(meetings, date);
            return '<section class="schedule-day stack" data-day="' + date + '"><div class="row"><button type="button" class="plain strong' +
                (date === startOfDay(selectedDay) ? ' selected-day' : '') + '" data-action="daySummary" data-payload="' + encoded({ date }) + '">' +
                html(capitalize(format(date, 'weekday'))) + '</button><span class="spacer"></span>' +
                iconButton('Создать событие', 'plus', 'createEvent', { start: defaultStart(date) }) + '</div>' +
                (events.map(meeting => resultRow(meeting, date)).join('') || '<span class="note">' +
                (state.syncing ? 'Загружаю встречи…' : coverageIncludes(date, addDays(date, 1)) ? 'Нет встреч' : 'Данные за этот день пока недоступны') + '</span>') + '</section>';
        }).join('') + button('Следующий месяц', 'move', { offset: 1 }, { glyph: 'right', className: 'plain' }) + '</div>';
}

function busyMeetings(meetings) {
    return meetings.filter(meeting => !meeting.allDay && !meeting.isFree && status(meeting) !== 'declined' && meeting.end > meeting.start);
}

function conflictsFor(meetings, selected) {
    const busy = busyMeetings(meetings);
    const results = [];
    busy.forEach((first, index) => {
        for (const second of busy.slice(index + 1)) {
            if (selected && first.id !== selected && second.id !== selected) continue;
            if (second.id !== first.id && intersects(second, first.start, first.end)) {
                results.push({ first, second, start: Math.max(first.start, second.start), end: Math.min(first.end, second.end) });
            }
        }
    });
    return results;
}

function dayInspector(visible, filtered) {
    const date = startOfDay(selectedDay);
    const events = onDay(filtered, date);
    const availability = onDay(visible, date);
    const complete = canShowFree(date, addDays(date, 1));
    const slots = freeSlots(date, visible);
    const conflicts = conflictsFor(availability);
    return '<div class="inspect-day stack scroll" data-scroll="inspector"><h2>' + html(capitalize(format(date, 'weekday'))) + '</h2>' +
        '<div class="row">' + button('Создать', 'createEvent', { start: defaultStart(date) }, { glyph: 'plus' }) + '</div>' +
        (complete ? '<section class="stack"><h3>Занятость</h3><span class="note">' + busyMeetings(availability).length +
            ' · занятые встречи' + (conflicts.length ? ' · ' + conflicts.length + ' пересечений' : '') +
            '</span>' + (slots.length ? '<h3>Свободные окна</h3>' + slots.map(([start, end]) => '<div class="row"><span class="spacer">' +
            html(format(start, 'time') + '–' + format(end, 'time')) + '</span>' + button('Запланировать ↗', 'freeSlot', { start, end }, { className: 'plain' }) + '</div>').join('') : '') +
            '</section><hr>' : '') + (events.length ? events.map(meeting => resultRow(meeting, date)).join('') :
        '<p class="empty">' + (state.syncing ? 'Загружаю встречи…' : 'Нет встреч') + '</p>') + '</div>';
}

function calendarView() {
    const dates = periodDays();
    const visible = activeVisibleMeetings();
    const filtered = filteredMeetings(visible);
    const selected = findMeeting(selectedId);
    const alert = state.warning ? '<div class="notice">' + icon('warning') + ' ' + html(state.warning) + '</div>' : '';
    const statusText = state.syncing ? 'Обновляю расписание…' : state.lastSync ? 'Проверено · ' + format(state.lastSync, 'dateTime') :
        activeAccounts().length ? 'Загрузка выбранного периода ещё не завершена' : 'Нет активных аккаунтов';
    const unread = (state.activity || []).filter(item => item.unread).length;
    return '<div class="calendar-app">' + toolbar(dates) + '<div class="workspace">' + calendarSidebar() +
        '<section class="calendar-body" aria-label="Календарь">' + alert + (mode === 'month' ? monthGrid(dates, filtered) :
            mode === 'agenda' ? scheduleGrid(dates, filtered) : timeline(dates, filtered, visible)) + '</section>' +
        (inspector ? '<aside class="inspector" aria-label="Подробности"><div class="inspect-head row">' +
        (selected ? iconButton('К сводке дня', 'left', 'daySummary', { date: selectedDay }) : '') +
        '<h3 class="spacer">' + (selected ? 'Встреча' : 'День') + '</h3>' +
        iconButton('Закрыть подробности · Esc', 'close', 'closeInspector') + '</div>' +
        (selected ? meetingDetails(selected, conflictsFor(onDay(visible, selectedDay), selected.id)) : dayInspector(visible, filtered)) + '</aside>' : '') +
        '</div><footer class="footer row"><span class="spacer ellipsis">' + html(statusText) + '</span>' +
        iconButton(unread ? 'История · ' + unread + ' непрочитанных' : 'История изменений', 'history', 'open', { view: 'activity' }) +
        iconButton('Настройки · Ctrl+,', 'gear', 'open', { view: 'settings' }) +
        iconButton('Обновить выбранный период', 'refresh', 'refreshCalendar', {}, { disabled: state.syncing }) + '</footer></div>';
}

function recurrence(meeting) {
    return Boolean(meeting.recurrenceRule || meeting.originalStart != null);
}

function pinnedMeeting(meeting) {
    return state.pins.find(pin => pin.url === meeting.link && pin.login === (meeting.accountLogin ?? state.primaryLogin ?? ''));
}

function isEventPage(value) {
    try {
        const url = new URL(value);
        return url.protocol === 'https:' && /^calendar\.yandex\.(ru|com|by|kz|uz)$/.test(url.hostname) && /\/event/.test(url.pathname + url.search);
    } catch {
        return false;
    }
}

function meetingDetails(meeting, conflicts = []) {
    const detailAction = (label, glyph, action, payload, options = {}) =>
        button(label, action, payload, { glyph, className: 'detail-action', ...options });
    const value = status(meeting);
    const canRespond = value === 'needsAction' || value === 'tentative';
    const hasEventPage = isEventPage(meeting.sourceURL);
    const exactOrDay = title => hasEventPage ? title : 'Открыть день в Яндексе';
    const pin = pinnedMeeting(meeting);
    const edit = title => button(exactOrDay(title), 'edit', { id: meeting.id }, { className: 'primary', glyph: 'out' });
    let primary;
    if (meeting.cancelled) {
        primary = '<div class="warning">' + icon('warning') + ' Встреча отменена</div>';
    } else if (canRespond) {
        primary = '<div class="row wrap">' + edit('Ответить в Яндексе') +
            (meeting.link ? button('Подключиться', 'join', { url: meeting.link }, { glyph: 'video' }) : '') + '</div>' +
            (hasEventPage ? '' : '<p class="note">Выберите встречу в Яндекс Календаре, чтобы ответить.</p>');
    } else if (meeting.link) {
        const label = /^https?:\/\/telemost\.yandex\./i.test(meeting.link) ? 'Яндекс Телемост' : 'Видеовстреча';
        primary = '<div class="row wrap callout"><strong class="spacer">' + icon('video') + ' ' + label + '</strong>' +
            button('Подключиться', 'join', { url: meeting.link }, { className: 'join' }) + '</div>';
    } else {
        primary = '<div>' + edit('Открыть в Яндексе') + '</div>';
    }
    const required = (meeting.attendees || []).filter(person => !person.optional);
    const optional = (meeting.attendees || []).filter(person => person.optional);
    const when = capitalize(format(meeting.start, 'weekday')) + ' · ' + timeLabel(meeting);
    const canSnooze = !meeting.cancelled && !meeting.allDay && meeting.end > currentTime();
    return '<article class="details-content" data-scroll="inspector"><header class="stack"><h1>' + html(meeting.title) + '</h1>' +
        '<span class="muted">' + icon('calendar') + ' ' + html(when) + '</span>' +
        (activeAccounts().length > 1 ? '<span class="muted">' + icon('person') + ' ' + html(accountName(meeting.accountLogin)) + '</span>' : '') +
        statusLabel(meeting, false, true) + '</header>' + primary + '<div class="row wrap details-actions">' +
        detailAction('В календаре', 'calendar', 'focusCalendar', { id: meeting.id }, { hint: 'Показать в календаре' }) +
        (meeting.link ? detailAction('Копировать ссылку', 'link', 'copyLink', { url: meeting.link }) : '') +
        (pin || meeting.link && !meeting.cancelled ? detailAction(pin ? 'Открепить' : 'Закрепить', 'pin', 'togglePin',
            { id: meeting.id }, { pressed: Boolean(pin) }) : '') +
        '<button type="button" class="plain icon color-action" data-action="meetingColor" data-payload="' + encoded({ id: meeting.id }) +
        '" aria-label="Цвет встречи" title="Цвет встречи"><span class="tint-dot" style="--tint:' + tint(meeting) + '"></span>' +
        icon('color') + '</button>' +
        (canSnooze || meeting.cancelled || !canRespond && meeting.link ? iconButton('Действия встречи', 'more', 'eventMenu', { id: meeting.id }) : '') +
        '</div>' + (conflicts.length ? '<section class="stack" style="padding:10px;border-radius:8px;background:color-mix(in srgb,var(--orange) 9%,transparent)">' +
        '<h3>' + icon('warning') + ' Пересечения</h3>' + conflicts.map(conflict => {
            const other = conflict.first.id === meeting.id ? conflict.second : conflict.first;
            return '<button class="plain" type="button" style="justify-content:flex-start" data-action="selectConflict" data-payload="' + encoded({ id: other.id }) +
                '"><span class="stack spacer" style="gap:2px"><strong>' + html(other.title) + '</strong><span class="note">' +
                html(format(conflict.start, 'time') + '–' + format(conflict.end, 'time') + ' · ' + duration((conflict.end - conflict.start) / minute)) +
                '</span></span>' + icon('right') + '</button>';
        }).join('') + '</section>' : '') + '<hr><section class="detail-list">' +
        (!meeting.cancelled && !meeting.allDay ? reminderLine(meeting) : '') +
        '<div class="row">' + icon('calendar') + '<span class="spacer">Календарь</span><span class="tint-dot" style="--tint:' + tint(meeting) + '"></span>' +
        '<span class="muted">' + html(calendarOf(meeting.calendarID)?.name || meeting.calendarName) + '</span></div>' +
        (required.length ? people(required, 'Участники', 'required') : '') + (optional.length ? people(optional, 'Необязательные участники', 'optional') : '') +
        (meeting.location ? '<div class="preserve">' + icon('location') + ' ' + html(meeting.location) + '</div>' : '') +
        (meeting.organizer ? '<div class="preserve">' + icon('person') + ' Организатор: ' + html(meeting.organizer) + '</div>' : '') +
        (recurrence(meeting) ? '<div class="muted">' + icon('repeat') + ' Повторяющаяся встреча</div>' : '') + '</section>' +
        (meeting.details ? '<hr><section class="stack"><h3>Описание</h3><div class="preserve">' + html(meeting.details) + '</div></section>' : '') + '</article>';
}

function people(peopleList, label, type) {
    return '<details data-disclosure="' + encoded(['people', selectedId || searchId || standaloneId, type]) + '"><summary>' +
        icon('people') + ' ' + html(label) + ' · ' + peopleList.length + '</summary><div class="stack" style="padding-top:8px">' +
        peopleList.map(person => '<span class="preserve">' + html([person.name, person.email].filter(Boolean).join(' · ') +
        (person.response?.toUpperCase() === 'DECLINED' ? ' · отказался' : '')) + '</span>').join('') + '</div></details>';
}

function reminderOffsets(meeting, setting) {
    if (setting?.muted) return [];
    if (setting?.minutes) return setting.minutes;
    const settings = accountSettings(meeting.accountLogin);
    return [...new Set([
        settings.firstReminderEnabled === false ? null : settings.firstReminderMinutes ?? 15,
        settings.secondReminderEnabled === false ? null : settings.secondReminderMinutes ?? 5
    ].filter(value => value != null))].sort((left, right) => right - left);
}

function reminderLine(meeting) {
    const occurrence = state.reminders?.[meeting.id];
    const series = state.reminders?.[meeting.seriesID];
    const offsets = reminderOffsets(meeting, occurrence ?? series);
    const scheduled = state.snoozes.find(item => item.meeting?.id === meeting.id);
    const now = currentTime();
    const next = offsets.map(offset => meeting.start - minute * offset).filter(at => at > now).sort((left, right) => left - right)[0];
    const note = meeting.end > now && status(meeting) !== 'declined' ?
        calendarOf(meeting.calendarID)?.notify === false ? 'Уведомления для этого календаря выключены' :
        scheduled ? 'Отложено до ' + format(scheduled.at, 'dateTime') : next ?
            'Ближайшее уведомление · ' + format(next, 'dateTime') : 'Нет запланированных уведомлений' : '';
    return '<div class="stack"><button type="button" class="plain wide-button" data-action="reminderEditor" data-payload="' + encoded({ id: meeting.id }) +
        '">' + icon('bell') + '<span class="spacer">Напоминания</span><span class="muted">' +
        (offsets.length ? 'За ' + html(offsets.join(' и ')) + ' мин.' : 'Выключены') + '</span>' + icon('right') + '</button>' +
        '<span class="note">' + (occurrence ? 'Для этой встречи' : series ? 'Для серии' : 'По умолчанию') + '</span>' +
        (note ? '<span class="note">' + html(note) + '</span>' : '') + '</div>';
}

function section(title, content) {
    return '<section class="settings-section stack"><h3>' + html(title) + '</h3>' + content + '</section>';
}

function settingRow(label, content, id = '') {
    return '<div class="setting-row">' + (id ? '<label for="' + html(id) + '">' + html(label) + '</label>' :
        '<span>' + html(label) + '</span>') + content + '</div>';
}

function settingToggle(label, key, checked) {
    return settingRow(label, checkbox(label, 'setting', { key }, checked, { toggle: true }));
}

function numericControl(label, key, value, min, max, disabled = false) {
    return '<input type="number" data-change="settingNumber" data-payload="' + encoded({ key }) +
        '" aria-label="' + html(label) + '" min="' + min + '" max="' + max + '" value="' + html(value) + '"' + (disabled ? ' disabled' : '') + '>';
}

function workdayTimeControl(start) {
    const [first, last] = workdayMinutes();
    const [hours, minutes] = clock(start ? first : last).split(':');
    const boundary = start ? 'начала' : 'окончания';
    const key = start ? 'workdayStart' : 'workdayEnd';
    return '<div class="workday-time">' +
        numericControl('Час ' + boundary, key + 'Hour', hours, 0, start ? 23 : 24) +
        '<span aria-hidden="true">:</span>' +
        numericControl('Минуты ' + boundary, key + 'Minute', minutes, 0, 59, hours === '24') + '</div>';
}

function accountForm(account, inDialog = false) {
    const editing = Boolean(account?.login);
    const name = editing ? 'Настройки аккаунта' : 'Добавление аккаунта';
    const draft = inDialog ? account || {} : initialDraft;
    const formTitle = inDialog ? '<h2 id="dialog-title">' + name + '</h2>' : '<h2>' + name + '</h2>';
    return '<form class="stack" data-form="account" style="gap:12px">' + formTitle +
        '<label class="field">Электронная почта' + (editing ? '<input type="hidden" name="login" value="' + html(account.login) + '"><span>' +
        html(account.login) + '</span>' : '<input type="email" name="login" value="' + html(draft.login) +
            '" required placeholder="name@example.com" autocomplete="username">') + '</label>' +
        '<label class="field">Название аккаунта<input name="label" autocomplete="off" value="' + html(draft.label) +
        '" placeholder="Например, Работа"></label><label class="field">Пароль приложения «Календарь»' +
        '<input name="password" type="password" autocomplete="current-password" ' + (editing ? '' : 'required') +
        '><span class="note">' + (editing ? 'Оставьте поле пустым, чтобы сохранить прежний пароль.' :
            'Создайте пароль приложения в Яндекс ID для сервиса «Календарь».') + '</span></label>' +
        '<div>' + button('Создать пароль в Яндекс ID', 'browser', { url: 'https://id.yandex.ru/security/app-passwords' }, { className: 'link' }) + '</div>' +
        '<label class="field">Часовой пояс<input name="zone" required value="' + html(draft.zone || draft.settings?.zone || 'Europe/Moscow') +
        '"><span class="note">Используется для встреч, у которых не указан часовой пояс.</span></label><hr>' +
        '<p class="warning" data-form-error role="alert"></p><div class="row">' +
        (editing ? '<button type="submit" name="verify" value="true">Проверить подключение</button>' : '') +
        '<span class="spacer"></span>' + (inDialog ? button('Отмена', 'closeDialog') : '') +
        '<button type="submit" class="primary">' + (editing ? 'Сохранить' : 'Подключить') + '</button></div></form>';
}

function settingsAccount(account) {
    const { login } = account;
    const primary = state.primaryLogin === login;
    const calendars = account.calendars || [];
    return '<section class="account stack"><div class="row">' + icon('person') + '<div class="stack spacer" style="gap:2px">' +
        '<span><strong>' + html(accountName(login)) + '</strong>' + (primary ? ' <span class="note">Основной</span>' : '') + '</span>' +
        (account.label ? '<span class="note">' + html(login) + '</span>' : '') + '</div><label class="row">Активен ' +
        checkbox('Активен · ' + accountName(login), 'account', { login, key: 'active' }, account.active !== false, { toggle: true }) + '</label>' +
        iconButton('Действия для аккаунта ' + accountName(login), 'more', 'accountMenu', { login }) + '</div>' +
        (account.error ? '<p class="warning">' + icon('warning') + ' ' + html(account.error) + '</p>' : '') +
        (!calendars.length ? '<p class="note">Календари пока не загружены</p>' :
            '<details data-disclosure="' + encoded(['account', login]) + '"><summary>Календари · ' + calendars.length +
            '</summary><div class="calendar-table"><span></span><strong class="note" style="text-align:center">В списке</strong>' +
            '<strong class="note" style="text-align:center">Уведомлять</strong>' + calendars.map(calendar =>
            '<div class="row"><input type="color" data-change="calendarTint" data-payload="' + encoded({ id: calendar.id }) +
            '" value="' + hex(calendar.color) + '" aria-label="' + html('Цвет календаря ' + calendar.name) + '"><span class="ellipsis">' +
            html(calendar.name) + '</span></div>' +
            checkbox('Показывать «' + calendar.name + '» в боковой панели', 'calendar', { id: calendar.id, key: 'listed' }, calendar.listed !== false) +
            checkbox('Уведомлять о событиях календаря «' + calendar.name + '»', 'calendar', { id: calendar.id, key: 'notify' }, calendar.notify !== false)
        ).join('') + '</div></details>') + '</section>';
}

function connectionSettings() {
    const title = state.syncing ? 'Обновляю расписание…' : state.lastSync ?
        'Расписание обновлено · ' + format(state.lastSync, 'dateTime') : state.accounts.length ?
        'Расписание ещё не загружено' : 'Подключите Яндекс Календарь';
    return '<header class="row"><h1 class="spacer">Подключение</h1>' +
        (state.accounts.length ? button('Добавить аккаунт', 'newAccount', {}, { glyph: 'plus' }) : '') + '</header>' +
        '<div class="row muted"><span class="spacer">' + icon(state.warning ? 'warning' : state.lastSync ? 'check' : 'info') + ' ' + html(title) + '</span>' +
        (activeAccounts().length ? button('Обновить', 'sync', {}, { glyph: 'refresh', disabled: state.syncing }) : '') + '</div>' +
        (state.warning ? '<p class="warning">' + html(state.warning) + '</p>' : '') + '<hr>' +
        (state.accounts.length ? state.accounts.map(settingsAccount).join('') +
        '<details data-disclosure="diagnostics"><summary>' + icon('info') + ' Диагностика подключения</summary>' +
        '<div class="stack note" style="padding:8px">' +
        '<span>Активные аккаунты · ' + activeAccounts().length + '</span>' +
        '<span>Календари · ' + activeAccounts().flatMap(account => account.calendars || []).length + '</span>' +
        '<span>Последняя синхронизация · ' + (state.lastSync ? html(format(state.lastSync, 'dateTime')) : 'нет данных') + '</span>' +
        '<span>Windows управляет разрешениями на уведомления</span></div></details>' : accountForm());
}

function notificationSettings() {
    const settings = state.settings;
    const row = (label, prefix, fallback) => settingRow(label,
        numericControl(label + ' · минут', prefix + 'Minutes', settings[prefix + 'Minutes'] ?? fallback, 1, 1440, settings[prefix + 'Enabled'] === false) +
        '<span class="note">мин.</span>' + checkbox(label, 'setting', { key: prefix + 'Enabled' }, settings[prefix + 'Enabled'] !== false, { toggle: true }));
    const time = clock((settings.dailyOverviewHour ?? 9) * 60 + (settings.dailyOverviewMinute ?? 0));
    return '<h1>Уведомления</h1><div class="stack"><div class="row"><span class="spacer">' + icon('bell') +
        ' ' + html(state.notificationStatus || 'Уведомления CalendarBar') + '</span>' + button('Проверить', 'testNotification') + '</div><div>' +
        button('Открыть параметры уведомлений Windows', 'notificationSettings', {}, { className: 'link' }) + '</div></div>' +
        (state.accounts.length > 1 ? '<p class="note">Настройки напоминаний и изменений · ' + html(accountName(state.primaryLogin)) +
            '. Чтобы изменить другой аккаунт, сделайте его основным в разделе «Подключение».</p>' : '') +
        section('Напоминания до встречи', row('Первое напоминание', 'firstReminder', 15) + '<hr>' + row('Повторное напоминание', 'secondReminder', 5) +
            '<p class="note">От 1 до 1440 минут. В карточке встречи можно задать личное исключение.</p>') +
        section('Изменения расписания', settingToggle('Новые встречи', 'notifyNew', settings.notifyNew !== false) + '<hr>' +
            settingToggle('Переносы, изменения и отмены', 'notifyChanges', settings.notifyChanges !== false) + '<hr>' +
            settingToggle('Изменения описания и участников', 'notifyMinorChanges', Boolean(settings.notifyMinorChanges)) +
            '<p class="note">Все обнаруженные изменения сохраняются в истории независимо от этих переключателей.</p>') +
        section('Краткий обзор дня', settingRow('Уведомлять утром',
            checkbox('Уведомлять утром', 'setting', { key: 'dailyOverviewEnabled' }, Boolean(settings.dailyOverviewEnabled), { toggle: true }) +
            '<input type="time" data-change="overviewTime" aria-label="Время уведомления" value="' + html(time) + '"' +
            (!settings.dailyOverviewEnabled ? ' disabled' : '') + '>') +
            '<p class="note">По календарям с включёнными уведомлениями. Данные обновляются, пока CalendarBar запущен.</p>');
}

function appearanceSettings() {
    const settings = state.settings;
    return '<h1>Вид</h1>' + settingRow('Тема оформления',
        select('Тема оформления', [['system', 'Системная'], ['light', 'Светлая'], ['dark', 'Тёмная']], state.appearance || 'system', 'setting', { key: 'appearance' })) +
        section('Область уведомлений', settingRow('Показывать отсчёт до встречи',
            select('Показывать отсчёт до встречи', [[0, 'Не показывать'], [15, 'За 15 минут'], [30, 'За 30 минут'], [60, 'За 1 час'], [180, 'За 3 часа']],
                settings.menuCountdownWindow ?? 60, 'settingNumber', { key: 'menuCountdownWindow' })) +
            '<p class="note">На значке CalendarBar доступен отсчёт до ближайшей встречи. В меню доступны текущие встречи, расписание и закреплённые ссылки.</p>') +
        section('Рабочий день', settingRow('Начало рабочего дня', workdayTimeControl(true)) +
            settingRow('Окончание рабочего дня', workdayTimeControl(false)) +
            '<p class="note">Для расчёта свободных промежутков от 30 минут. События на весь день и события со статусом «свободен» не занимают эти промежутки.</p><hr>' +
            settingToggle(workdayOnlyTitle, 'workdayOnly', settings.workdayOnly !== false) +
            '<p class="note">В видах «День» и «Неделя» сетка расширяется до начала ранней встречи или конца поздней.</p>') +
        '<p class="note">Вид календаря, выбранные календари и состояние панелей запоминаются.</p>';
}

function generalSettings() {
    const settings = state.settings;
    return '<h1>Основные</h1>' + settingToggle('Запускать при входе в Windows', 'autoStart', Boolean(settings.autoStart)) +
        section('Синхронизация с Яндекс Календарём', settingRow('В рабочее время',
            select('Интервал обновления в рабочее время', [[1, '1 мин'], [3, '3 мин'], [5, '5 мин (рекомендуется)'], [10, '10 мин'], [15, '15 мин']],
                settings.workdayRefreshMinutes ?? 5, 'settingNumber', { key: 'workdayRefreshMinutes' })) +
            settingRow('Вне рабочего времени', select('Интервал обновления вне рабочего времени',
                [[0, 'Не обновлять'], [15, '15 мин'], [30, '30 мин'], [60, '1 ч'], [120, '2 ч']],
                settings.outsideRefreshMinutes === undefined ? 30 : settings.outsideRefreshMinutes ?? 0, 'settingNumber', { key: 'outsideRefreshMinutes' })) +
            '<p class="note">Рабочее время · пн–пт, ' + html(workdayMinutes().map(clock).join('–')) +
            ' по времени Windows. Время можно изменить в разделе «Вид → Рабочий день».</p><p class="note">Ручное обновление доступно в любое время.</p>') +
        '<p>Закрытие окна оставляет CalendarBar в области уведомлений. Команда «Выход» завершает работу и фоновые проверки.</p>' +
        '<p>Без сети доступен сохранённый календарь. Время последнего обновления видно рядом с расписанием.</p>' +
        (state.warning ? '<p class="warning">' + html(state.warning) + '</p>' : '') +
        '<div>' + button('Открыть историю изменений', 'open', { view: 'activity' }) + '</div>';
}

function cacheSize(bytes) {
    const units = ['КБ', 'МБ', 'ГБ'];
    let scaled = bytes / 1000;
    let unit = 0;
    while (scaled >= 1000 && unit < units.length - 1) {
        scaled /= 1000;
        unit++;
    }
    if (bytes > 0 && bytes < 1000) return bytes.toLocaleString('ru-RU') + ' Б';
    return scaled.toLocaleString('ru-RU', { maximumFractionDigits: 1 }) + ' ' + units[unit];
}

function cacheSettings() {
    const bytes = state.cacheBytes ?? {};
    const total = Object.values(bytes).reduce((sum, size) => sum + size, 0);
    return '<h1>Кэш календаря</h1><div class="cache-summary row">' + icon('drive') +
        '<div class="spacer"><h3>Занято кэшем</h3><strong>' + html(cacheSize(total)) + '</strong></div>' +
        button('Очистить весь кэш', 'confirmCacheClear', {}, { disabled: state.syncing || !total }) + '</div>' +
        '<p class="muted">Обновление загрузит ближайшие встречи заново. За более ранние даты события можно загрузить в календаре или поиске.</p>' +
        (state.accounts.length ? section('По аккаунтам', state.accounts.map(({login, label}) =>
            '<div class="row cache-account"><div class="spacer stack"><strong class="ellipsis" title="' + html(login) + '">' +
            html(label || login) + '</strong>' + (label ? '<span class="note ellipsis">' + html(login) + '</span>' : '') +
            '</div><span class="muted">' + html(cacheSize(bytes[login] ?? 0)) + '</span>' +
            button('Очистить…', 'confirmCacheClear', { login }, { hint: 'Очистить кэш аккаунта ' + (label || login),
                disabled: state.syncing || !bytes[login] }) + '</div>').join('')) :
            '<p class="muted">Сохранённых аккаунтов пока нет.</p>') +
        (state.syncing ? '<p class="note">Очистка доступна после окончания загрузки.</p>' : '') +
        '<p class="note" role="status">' + html(cacheFeedback) + '</p>';
}

function settingsView() {
    const panes = { accounts: connectionSettings, notifications: notificationSettings, appearance: appearanceSettings,
        general: generalSettings, cache: cacheSettings };
    return '<div class="settings"><nav class="settings-nav stack" aria-label="Разделы настроек">' +
        Object.entries(pages).map(([key, [title, glyph]]) => '<button type="button" class="plain" ' +
            (page === key ? 'aria-current="page" ' : '') + 'data-action="settingsPage" data-payload="' + encoded({ page: key }) + '">' + icon(glyph) + html(title) + '</button>').join('') +
        '<span class="spacer"></span>' +
        button('Проект на GitHub', 'browser', { url: 'https://github.com/n-bord/calendarbar' }, { className: 'link' }) +
        '<span class="note">Версия ' + html(state.version) +
        '</span></nav><section class="settings-pane stack" data-scroll="settings-' + page + '">' + panes[page]() + '</section></div>';
}

function groupByDate(items, dateOf, descending = false) {
    const groups = new Map();
    for (const item of items) {
        const date = startOfDay(dateOf(item));
        if (!groups.has(date)) groups.set(date, []);
        groups.get(date).push(item);
    }
    return [...groups.entries()].sort(([first], [second]) => descending ? second - first : first - second);
}

function searchMatches() {
    return activeVisibleMeetings().filter(meeting => intersects(meeting, searchFrom, searchTo) && matches(meeting, searchQuery));
}

function searchView() {
    const selected = findMeeting(searchId);
    if (selected) {
        return '<div class="search-view stack"><div class="row">' + button('К результатам', 'searchBack', {}, { glyph: 'left' }) +
            '<span class="spacer"></span>' + button('Готово', 'close') + '</div><hr>' + meetingDetails(selected) + '</div>';
    }
    const matches = searchMatches();
    const groups = groupByDate(matches, meeting => Math.max(meeting.start, searchFrom));
    const byId = new Map(matches.map((meeting, index) => [meeting.id, index]));
    const label = format(searchFrom, 'day') + '–' + format(addDays(searchTo, -1), 'day');
    const empty = searchLoading ? 'Загружаю встречи…' : !activeAccounts().length ? 'Включите аккаунт в настройках, чтобы искать встречи.' :
        searchError ? 'В сохранённых данных совпадений нет.' : 'В этом периоде ничего не найдено. Попробуйте другой запрос или даты.';
    return '<div class="search-view stack"><header class="row"><h2 class="spacer">Поиск встреч</h2>' + button('Готово', 'close') + '</header>' +
        '<div class="search-field">' + icon('search') + searchInput('search-query', 'Название, участник, описание или место', searchQuery, 'searchQuery') +
        (searchQuery ? iconButton('Очистить запрос', 'close', 'clearQuery') : '') + '</div>' +
        '<div class="row">' + button('Период', 'searchPeriod', {}, { glyph: 'calendar' }) + '<span class="note">' + html(label) +
        '</span>' + (searchLoading ? '<span class="note">Загрузка…</span>' : '') + '</div><hr><div class="stack scroll" data-scroll="results">' +
        (searchError ? '<p class="warning">' + icon('warning') + ' ' + html(searchError) + '</p>' : '') +
        (groups.length ? groups.map(([date, meetings]) => '<section class="stack"><h3 class="muted">' + html(relativeDay(date)) + '</h3>' +
            meetings.map(meeting => resultRow(meeting, date, { search: true, action: 'searchMeeting', highlight: highlighted === byId.get(meeting.id) })).join('') +
            '</section>').join('') : '<p class="empty">' + empty + '</p>') + '</div></div>';
}

function pinsFor(login) {
    return state.pins.filter(pin => pin.login === login || (!pin.login && !login));
}

function pinnedView() {
    const login = pinLogin ?? state.primaryLogin ?? '';
    const pins = pinsFor(login);
    const options = state.accounts.map(account => [account.login, accountName(account.login)]);
    const editing = pins.find(pin => pin.id === pinEdit);
    return '<div class="pinned-view stack">' + (options.length > 1 ?
        settingRow('Аккаунт', select('Аккаунт', options, login, 'pinLogin')) : '') +
        '<form class="stack" data-form="pin"><h3>' + (editing ? 'Изменить встречу' : 'Добавить встречу') + '</h3>' +
        '<input name="title" required aria-label="Название встречи" placeholder="Название, например «Командная комната»" value="' + html(editing?.title) +
        '"><input name="url" type="url" required aria-label="Ссылка для подключения" placeholder="Ссылка для подключения" value="' + html(editing?.url) +
        '"><p class="warning" data-form-error role="alert"></p><div class="row">' +
        (editing ? button('Отменить правку', 'resetPin') : '') + '<span class="spacer"></span><button type="submit" class="primary">' +
        (editing ? 'Сохранить' : 'Закрепить') + '</button></div></form><hr>' +
        (pins.length ? '<div class="pin-list stack" data-scroll="pins">' + pins.map((pin, index) =>
            '<div class="row">' + button(pin.title, 'editPin', { id: pin.id }, { className: 'plain pin-title' }) +
            iconButton('Выше', 'up', 'pin', { id: pin.id, login, offset: -1 }, { disabled: index === 0 }) +
            iconButton('Ниже', 'down', 'pin', { id: pin.id, login, offset: 1 }, { disabled: index === pins.length - 1 }) +
            iconButton('Открепить', 'close', 'removePin', { id: pin.id, login }) + '</div>').join('') + '</div>' :
            '<p class="muted">Скопируйте ссылку на звонок из Телемоста или другого сервиса и вставьте её выше.</p>') + '</div>';
}

let unreadOnly = false;

function activityView() {
    const history = state.activity;
    const snoozes = state.snoozes.filter(item => item.at > currentTime()).slice().sort((a, b) => a.at - b.at);
    const visible = history.filter(item => !unreadOnly || item.unread);
    return '<div class="activity-view stack"><h1>Изменения и напоминания</h1><div class="row"><div class="segments" role="group" aria-label="Фильтр истории">' +
        button('Все', 'activityFilter', { unread: false }, { pressed: !unreadOnly }) +
        button('Непрочитанные', 'activityFilter', { unread: true }, { pressed: unreadOnly }) + '</div><span class="spacer"></span>' +
        iconButton('Действия с историей', 'more', 'activityMenu') + '</div><hr><div class="stack scroll" data-scroll="activity">' +
        (snoozes.length ? '<h3 class="muted">Отложенные напоминания</h3>' + snoozes.map(item =>
            '<div class="result-row">' + button(item.meeting.title, 'open', { view: 'meeting', meeting: item.meeting.id }, { glyph: 'bell', className: 'plain' }) +
            '<span class="note">' + html(format(item.at, 'dateTime')) + '</span>' +
            button('Убрать', 'snooze', { id: item.meeting.id, cancel: true }) + '</div>').join('') : '') +
        (visible.length ? groupByDate(visible, item => item.at, true).map(([date, items]) =>
            '<h3 class="muted">' + html(relativeDay(date)) + '</h3>' + items.map(historyItem).join('')).join('') :
            '<h3>' + (unreadOnly ? 'Непрочитанных изменений нет' : 'Изменений пока нет') + '</h3>' +
            (unreadOnly ? '' : '<p class="note">Здесь появятся новые встречи, переносы и отмены после проверки календаря.</p>')) + '</div></div>';
}

function historyItem(item) {
    const meeting = displayedMeeting(item.meeting);
    if (!meeting) return '';
    const prior = displayedMeeting(item.previous);
    const timeChanged = prior && (prior.start !== meeting.start || prior.end !== meeting.end);
    const linkChanged = prior && prior.link !== meeting.link;
    const title = ({ new: 'Новая встреча', changed: 'Встреча изменена', cancelled: 'Встреча отменена' })[item.kind] || 'Изменение';
    return '<article class="result-row stack" style="align-items:stretch"><button type="button" class="plain" data-action="openActivity" data-payload="' +
        encoded({ id: item.id, meeting: meeting.id }) + '"><span class="stack spacer" style="gap:3px"><span class="row"><span class="spacer note">' +
        (item.unread ? '● ' : '') + html(title) + '</span><span class="note">' + html(format(item.at, 'time')) + '</span></span><strong>' + html(meeting.title) +
        '</strong><span class="note">' + html(meeting.calendarName) + '</span>' +
        (timeChanged ? '<span class="note">' + html(timeLabel(prior) + ' → ' + timeLabel(meeting)) + '</span>' : '') +
        '</span>' + icon('right') + '</button>' +
        (!meeting.cancelled && (timeChanged || linkChanged && meeting.link) ? '<div class="row wrap">' +
            (timeChanged ? button('Показать новое время', 'focusActivity', { id: item.id, meeting: meeting.id }, { glyph: 'calendar' }) : '') +
            (linkChanged && meeting.link ? button('Копировать ссылку', 'copyLink', { url: meeting.link }, { glyph: 'link' }) : '') + '</div>' : '') +
        '</article>';
}

function trayItem(meeting, style = '', restore = false) {
    const title = style === 'last' ? 'Последняя встреча' : meeting.title;
    const sub = style === 'last' ? timeLabel(meeting) + ' · ' + meeting.title : [
        timeLabel(meeting), activeAccounts().length > 1 && accountName(meeting.accountLogin),
        style === 'featured' && countdown(meeting)
    ].filter(Boolean).join(' · ');
    return '<article class="tray-item row ' + html(style) + '" data-meeting="' + html(meeting.id) + '">' +
        (style === 'featured' ? icon(meeting.link ? 'video' : 'calendar') : '') +
        '<button type="button" class="plain" data-action="open" data-payload="' + encoded({ view: 'meeting', meeting: meeting.id }) +
        '"><span class="line"><span class="row"><strong class="ellipsis">' + html(title) + '</strong>' +
        (style === 'past' ? '' : statusLabel(meeting, true)) + '</span><span class="note ellipsis" style="display:block">' +
        html(sub) + '</span></span></button>' +
        (meeting.link ? button(style === 'last' ? 'Вернуться' : style === 'past' ? 'Войти' : 'Подключиться',
            'join', { url: meeting.link }, { className: style === 'featured' || style === 'last' ? 'join' : '' }) : '') +
        (style === 'last' ? iconButton('Убрать последнюю встречу', 'close', 'hideLast', { id: meeting.id, hidden: true }) : '') +
        (restore ? iconButton('Вернуть последнюю встречу', 'restore', 'hideLast', { id: meeting.id, hidden: false }) : '') + '</article>';
}

function countdown(meeting) {
    const difference = Math.ceil((meeting.start - currentTime()) / minute);
    return difference <= 0 ? 'Сейчас по расписанию' : 'Через ' + duration(difference);
}

function traySection(label, glyph, content, name) {
    return '<details class="tray-section" data-disclosure="tray-' + name + '"><summary>' +
        icon(glyph) + '<span>' + html(label) + '</span></summary>' + content + '</details>';
}

function trayView() {
    const now = currentTime();
    const today = startOfDay(now);
    const tomorrow = addDays(today, 1);
    const horizon = addDays(now, 14);
    const accounts = activeAccounts();
    const visible = activeVisibleMeetings().filter(meeting => status(meeting) !== 'declined' && meeting.end > meeting.start);
    const menuMode = state.settings.menuMeetingsMode || 'currentAndUpcoming';
    const eligible = visible.filter(meeting => {
        if (menuMode === 'allToday') return intersects(meeting, today, tomorrow);
        if (menuMode === 'upcomingOnly') return meeting.start > now && meeting.start < horizon;
        if (menuMode === 'currentOnly') return meeting.start <= now && meeting.end > now;
        return meeting.end > now && meeting.start < horizon || intersects(meeting, today, tomorrow);
    });
    const timed = eligible.filter(meeting => !meeting.allDay);
    const ongoing = timed.filter(meeting => meeting.start <= now && meeting.end > now);
    const upcoming = timed.filter(meeting => meeting.start > now);
    const next = upcoming.filter(meeting => meeting.start === upcoming[0]?.start);
    const featured = ongoing[0] || next.find(meeting => startOfDay(meeting.start) === today && meeting.start - now <= 15 * minute);
    const scheduleNow = ongoing.filter(meeting => meeting.id !== featured?.id);
    const scheduleNext = next.filter(meeting => meeting.id !== featured?.id);
    const rest = upcoming.filter(meeting => !next.some(item => item.id === meeting.id));
    const laterToday = rest.filter(meeting => meeting.start < tomorrow);
    if (featured && !scheduleNext.length && laterToday.length) scheduleNext.push(laterToday.shift());
    const later = rest.filter(meeting => meeting.start >= tomorrow);
    const allDay = eligible.filter(meeting => meeting.allDay && intersects(meeting, today, tomorrow));
    const finished = timed.filter(meeting => meeting.end <= now).sort((left, right) => right.end - left.end);
    const yesterdayEnd = yesterdayLast(visible, today, menuMode);
    const last = finished[0] || yesterdayEnd;
    const hidden = Boolean(last && state.hiddenLast?.[last.accountLogin] === last.id);
    const earlier = finished.filter(meeting => hidden || meeting.id !== last?.id);
    const pins = [].concat(pinsFor(state.primaryLogin || ''), accounts.filter(account => account.login !== state.primaryLogin)
        .flatMap(account => pinsFor(account.login)), state.primaryLogin ? pinsFor('') : []).filter((pin, index, list) =>
        list.findIndex(other => other.url === pin.url) === index);
    const sections = [];
    if (!accounts.length) {
        sections.push('<div>' + button(state.accounts.length ? 'Включить аккаунт' : 'Подключить календарь', 'open', { view: 'settings' }) + '</div>');
    } else if (featured) {
        sections.push(trayItem(featured, 'featured'));
    } else if (coverageIncludes(today, tomorrow) && !laterToday.length && !upcoming.some(meeting => meeting.start < tomorrow)) {
        sections.push('<p class="muted" style="padding:5px 8px">' + icon('calendar') + ' ' +
            (allDay.length ? 'Сегодня остались события на весь день' : 'Сегодня встреч больше нет') + '</p>');
    }
    if (scheduleNow.length) sections.push('<h3>Сейчас по расписанию</h3>' + scheduleNow.map(meeting => trayItem(meeting)).join(''));
    if (scheduleNext.length) {
        const nextMeeting = scheduleNext[0];
        const summary = html((startOfDay(nextMeeting.start) === today ? format(nextMeeting.start, 'time') :
            format(nextMeeting.start, 'dateTime')) + ' · ' + nextMeeting.title);
        sections.push(scheduleNext.length === 1 ? '<button type="button" class="plain tray-next" data-action="open" data-payload="' +
            encoded({ view: 'meeting', meeting: nextMeeting.id }) + '">' +
            icon('clock') + '<span class="stack spacer" style="gap:2px"><strong>Далее</strong><span class="note ellipsis">' + summary +
            '</span></span>' + icon('right') + '</button>' : traySection('Далее · ' + scheduleNext.length, 'clock',
                '<p class="note">' + summary + '</p>' + trayGrouped(scheduleNext), 'next'));
    }
    sections.push(traySection('Закреплённые', 'pin', pins.map(pin => '<div class="tray-item row"><span class="spacer ellipsis" title="' +
        html(pin.title) + '">' + html(pin.title) + '</span>' + button('Войти', 'join', { url: pin.url }, { glyph: 'video' }) + '</div>').join('') +
        button(pins.length ? 'Управлять закреплёнными…' : 'Закрепить по ссылке…', 'open', { view: 'pinned' }, { className: 'plain' }), 'pins'));
    if (last && !hidden) sections.push('<div class="tray-section">' + trayItem(last, 'last') + '</div>');
    if (allDay.length) sections.push(traySection('Весь день · ' + allDay.length, 'sun', allDay.map(meeting => trayItem(meeting)).join(''), 'all'));
    if (laterToday.length) sections.push(traySection('Ещё сегодня · ' + laterToday.length, 'clock', laterToday.map(meeting => trayItem(meeting)).join(''), 'today'));
    if (later.length) sections.push(traySection('Позже · ' + later.length, 'calendar', trayGrouped(later), 'later'));
    if (earlier.length) sections.push(traySection('Ранее сегодня · ' + earlier.length, 'history', earlier.map(meeting =>
        trayItem(meeting, 'past', meeting.id === last?.id)).join(''), 'earlier'));
    if (yesterdayEnd && last === yesterdayEnd && hidden) sections.push(traySection('Вчера', 'history', trayItem(yesterdayEnd, 'past', true), 'yesterday'));
    const syncStatus = state.syncing ? state.syncMessage || 'Обновляю расписание…' : state.warning ?
        'Не удалось полностью обновить расписание' : !state.lastSync ? 'Расписание ещё не загружено' :
        !coverageIncludes(today, tomorrow) ? 'Показаны сохранённые встречи' : '';
    return '<div class="tray-view stack"><h2>' + html(capitalize(format(now, 'weekday'))) + '</h2>' +
        (accounts.length && syncStatus ? '<p class="note' + (state.warning ? ' warning' : '') + '" style="padding-inline:4px">' +
        icon(state.warning ? 'warning' : 'clock') + ' ' + html(syncStatus) +
        (state.lastSync ? ' · ' + html(format(state.lastSync, 'dateTime')) : '') + '</p>' : '') +
        '<div class="tray-sections scroll" data-scroll="tray"><div class="stack">' + sections.join('') + '</div></div><hr>' +
        '<footer class="tray-footer row">' + button('Календарь', 'open', { view: 'calendar' }, { glyph: 'out', className: 'plain' }) +
        '<span class="spacer"></span>' + iconButton('Изменения и напоминания', 'history', 'open', { view: 'activity' }) +
        iconButton('Управлять закреплёнными', 'plus', 'open', { view: 'pinned' }) +
        iconButton('Настройки · Ctrl+,', 'gear', 'open', { view: 'settings' }) +
        iconButton('Обновить встречи', 'refresh', 'sync', {}, { disabled: state.syncing }) +
        iconButton('Действия приложения', 'more', 'trayMenu') + '</footer></div>';
}

function trayGrouped(meetings) {
    return groupByDate(meetings, meeting => meeting.start).map(([date, events]) => '<div class="stack" style="gap:2px"><h3 class="note">' +
        html(relativeDay(date)) + '</h3>' + events.map(meeting => trayItem(meeting)).join('') + '</div>').join('');
}

function yesterdayLast(meetings, today, menuMode) {
    if (menuMode !== 'allToday' && menuMode !== 'currentAndUpcoming') return null;
    const yesterday = addDays(today, -1);
    return meetings.filter(meeting => !meeting.allDay && meeting.end > yesterday && meeting.end <= today)
        .sort((left, right) => right.end - left.end)[0] || null;
}

function standaloneView() {
    const meeting = findMeeting(standaloneId) || displayedMeeting(state.focusMeeting);
    return meeting ? meetingDetails(meeting) : '<p class="empty" style="padding:25px">Выберите встречу в календаре или области уведомлений.</p>';
}

const views = { calendar: calendarView, settings: settingsView, search: searchView, pinned: pinnedView, activity: activityView, tray: trayView, meeting: standaloneView };

function decodePayload(element) {
    return element.dataset.payload ? JSON.parse(element.dataset.payload) : {};
}

function captureForms() {
    return [...app.querySelectorAll('form')].map(form => ({
        name: form.dataset.form,
        initialized: form.dataset.form !== 'pin' || pinEdit,
        fields: [...form.elements].filter(input => input instanceof HTMLInputElement && input.name && input.type !== 'hidden')
            .map(input => [input.name, input.value]),
        error: form.querySelector('[data-form-error]')?.textContent
    }));
}

function restoreForms(forms) {
    for (const data of forms) {
        const form = [...app.querySelectorAll('form')].find(element => element.dataset.form === data.name);
        if (!form || data.name === 'pin' && data.initialized !== (pinEdit || false)) continue;
        for (const [name, value] of data.fields) {
            if (form.elements[name]) form.elements[name].value = value;
        }
        const error = form.querySelector('[data-form-error]');
        if (error) error.textContent = data.error || '';
    }
}

function captureFocus() {
    const element = document.activeElement;
    if (!app.contains(element)) return null;
    const descriptor = { id: element.id, form: element.form?.dataset.form, name: element.name, label: element.getAttribute('aria-label'),
        action: element.dataset.action, change: element.dataset.change, payload: element.dataset.payload,
        start: element.selectionStart, end: element.selectionEnd, tag: element.tagName };
    return descriptor;
}

function restoreFocus(descriptor) {
    if (!descriptor) return;
    const { id, form, name, label, action, change, payload, tag, start, end } = descriptor;
    const element = id && document.getElementById(id) ||
        form && [...app.querySelectorAll('form')].find(element => element.dataset.form === form)?.elements[name] ||
        [...app.querySelectorAll('input, select, button')].find(element => tag === element.tagName &&
            ((action || change) && element.dataset.action === action && element.dataset.change === change &&
                element.dataset.payload === payload || label && element.getAttribute('aria-label') === label));
    if (!element?.focus) return;
    element.focus({ preventScroll: true });
    if (start != null && element.setSelectionRange) element.setSelectionRange(start, end);
}

function fitTrayToContent() {
    const content = app.querySelector('.tray-sections');
    if (!content) return;
    const chrome = app.clientHeight - content.clientHeight;
    const height = Math.max(132, Math.min(565, Math.ceil(chrome + content.firstElementChild.getBoundingClientRect().height)));
    if (height !== lastTrayHeight) {
        lastTrayHeight = height;
        void invoke('fitTray', { height }, { quiet: true });
    }
}

function render({ preserveForms = true, preserveFocus = true } = {}) {
    const scrolls = new Map([...app.querySelectorAll('[data-scroll]')].map(element => [element.dataset.scroll, element.scrollTop]));
    for (const element of app.querySelectorAll('[data-disclosure]')) disclosure.set(element.dataset.disclosure, element.open);
    const forms = preserveForms ? captureForms() : [];
    const focus = preserveFocus ? captureFocus() : null;
    document.documentElement.dataset.theme = state.appearance || 'system';
    app.innerHTML = (views[view] || calendarView)();
    for (const element of app.querySelectorAll('[data-disclosure]')) element.open = disclosure.get(element.dataset.disclosure) === true;
    if (view === 'tray') {
        // The tray window may still be hidden, where resize notifications can be deferred.
        if (lastTrayHeight === undefined) fitTrayToContent();
        trayObserver ??= new ResizeObserver(fitTrayToContent);
        trayObserver.disconnect();
        trayObserver.observe(app.querySelector('.tray-sections > .stack'));
    }
    for (const element of app.querySelectorAll('[data-scroll]')) element.scrollTop = scrolls.get(element.dataset.scroll) || 0;
    restoreForms(forms);
    restoreFocus(focus);
    if (view === 'calendar' && scrollIntent) scrollCalendar();
}

function scrollCalendar() {
    const intent = scrollIntent;
    scrollIntent = '';
    if (mode === 'agenda') {
        app.querySelector('[data-day="' + startOfDay(selectedDay) + '"]')?.scrollIntoView({ block: 'start' });
        return;
    }
    const timeline = app.querySelector('.timeline-scroll');
    if (!timeline) return;
    const first = Number(timeline.dataset.minute);
    const focus = findMeeting(selectedId);
    const target = intent === 'event' && focus && !focus.allDay ? Math.floor(timelineMinute(focus.start) / 60) * 60 - 60 :
        state.settings.workdayOnly === false ? 8 * 60 : first;
    timeline.scrollTop = Math.max(0, (target - first) * 52 / 60);
}

function applyState(next) {
    if (!next || !next.settings) return;
    const previous = state;
    state = next;
    if (selectedId) {
        const meeting = previous.meetings.find(item => item.id === selectedId) ??
            previous.activity.find(entry => entry.meeting?.id === selectedId)?.meeting;
        const login = meeting?.accountLogin;
        if (login && previous.cacheRevisions?.[login] !== state.cacheRevisions?.[login]) closeInspector();
    }
    mode = Object.hasOwn(modes, state.settings.calendarView) ? state.settings.calendarView : 'week';
    if (state.focusToken !== focusToken) {
        focusToken = state.focusToken;
        const focused = displayedMeeting(state.focusMeeting);
        if (view === 'calendar' && focused) {
            if (!matches(focused, filter)) filter = '';
            if (status(focused) === 'declined') {
                showDeclined = true;
                localStorage.setItem('showDeclined', 'true');
            }
            navigate(+(state.focusDate ?? focused.start), { refresh: false });
            selectedId = focused.id;
            inspector = true;
            compactSidebar = false;
            scrollIntent = 'event';
        } else if (view === 'calendar' && state.focusDate) {
            navigate(+state.focusDate, { refresh: false });
        } else if (view === 'meeting') {
            standaloneId = focused?.id || '';
        } else if (view === 'search' && state.focusQuery !== undefined) {
            searchQuery = state.focusQuery;
            searchId = '';
            highlighted = -1;
        }
    }
    if (view === 'calendar' && selectedId && previous.meetings.length && !activeVisibleMeetings().some(meeting => meeting.id === selectedId)) {
        const selected = findMeeting(selectedId);
        const calendar = selected && calendarOf(selected.calendarID);
        const login = selected && profile(selected.accountLogin);
        if (!calendar || calendar.visible === false || calendar.listed === false || login?.visible === false || login?.active === false) closeInspector();
    }
    if (view === 'search' && searchId && !searchMatches().some(meeting => meeting.id === searchId)) searchId = '';
    if (view === 'pinned' && pinLogin !== undefined && !state.accounts.some(account => account.login === pinLogin)) {
        pinLogin = state.primaryLogin;
        pinEdit = undefined;
    }
    render();
    if (view === 'calendar') loadCalendar();
}

function notice(message) {
    const toast = document.querySelector('#toast');
    toast.textContent = message || '';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.textContent = ''; }, 3300);
}

async function invoke(type, payload = {}, { quiet = false } = {}) {
    try {
        const result = await api.action(type, payload);
        if (result?.ok === false) throw new Error(result.error || 'Действие не удалось.');
        return result ?? { ok: true };
    } catch (error) {
        if (!quiet) notice(error.message);
        return { ok: false, error: error.message };
    }
}

function loadCalendar(force = false) {
    const dates = periodDays();
    const from = dates[0];
    const to = addDays(dates.at(-1), 1);
    const accounts = activeAccounts().map(account => account.login + ':' + (account.settings?.zone ?? ''));
    const next = JSON.stringify([from, to, accounts]);
    if (force || next !== rangeKey) {
        rangeKey = next;
        if (accounts.length) void invoke(force ? 'sync' : 'load', { from, to }, { quiet: !force });
    }
}

async function runSearch() {
    if (!activeAccounts().length) return;
    const from = searchFrom;
    const to = searchTo;
    searchLoading = true;
    searchError = '';
    render();
    const result = await invoke('search', { from, to }, { quiet: true });
    if (from === searchFrom && to === searchTo) {
        searchLoading = false;
        searchError = result.ok === false ? result.error : '';
        render();
    }
}

function navigate(date, { summary = false, refresh = true } = {}) {
    if (!Number.isFinite(date)) return;
    anchor = date;
    selectedDay = date;
    localStorage.setItem('calendarAnchor', String(anchor));
    if (selectedId) closeInspector();
    if (summary) inspector = true;
    popover = '';
    scrollIntent = 'period';
    if (refresh) {
        render();
        loadCalendar();
    }
}

function closeInspector() {
    inspector = false;
    selectedId = '';
}

function selectMeeting(id, date) {
    const meeting = findMeeting(id);
    if (!meeting) return;
    selectedId = meeting.id;
    selectedDay = date ?? meeting.start;
    inspector = true;
    compactSidebar = false;
    popover = '';
    render();
}

function openDialog(body) {
    closeContext();
    if (dialog.open) dialog.close();
    dialog.innerHTML = body;
    dialog.showModal();
}

function confirmAction(title, message, action, label) {
    openDialog('<form class="stack" data-form="confirm" data-payload="' + encoded(action) +
        '"><h2 id="dialog-title">' + html(title) + '</h2><p class="muted">' + html(message) + '</p><p class="warning" data-form-error></p><div class="row">' +
        button('Отмена', 'closeDialog') + '<span class="spacer"></span><button class="primary" type="submit">' + html(label) + '</button></div></form>');
}

function reminderDialog(meeting, scope = 'occurrence') {
    const setting = state.reminders?.[scope === 'series' ? meeting.seriesID : meeting.id];
    const inherited = scope === 'occurrence' && state.reminders?.[meeting.seriesID];
    const kind = setting ? setting.muted ? 'muted' : 'custom' : 'default';
    const offsets = reminderOffsets(meeting, setting || inherited);
    const options = [['default', inherited ? 'Как у серии' : 'По умолчанию'], ['custom', 'Свои интервалы'], ['muted', 'Не напоминать']];
    openDialog('<form class="stack" data-form="reminder" data-payload="' + encoded({ id: meeting.id }) +
        '"><h2 id="dialog-title">Личные напоминания</h2><strong>' + html(meeting.title) + '</strong>' +
        (recurrence(meeting) ? settingRow('Применить к', select('Применить к', [['occurrence', 'Этой встрече'], ['series', 'Всей серии']],
            scope, 'reminderScope', { id: meeting.id }, 'scope-select')) : '') +
        '<fieldset class="stack" style="margin:0;border:0;padding:0"><legend>Режим</legend>' +
        options.map(([value, title]) => '<label class="row"><input name="kind" type="radio" data-change="reminderKind" value="' + value +
            '"' + (value === kind ? ' checked' : '') + '>' + html(title) + '</label>').join('') + '</fieldset>' +
        '<div class="stack dialog-section" data-reminder-custom' + (kind === 'custom' ? '' : ' hidden') + '>' +
        '<label class="row">Напомнить за <input type="number" name="first" min="1" max="1440" value="' + (offsets[0] ?? 15) + '"> мин.</label>' +
        '<label class="row"><input type="checkbox" name="secondEnabled" data-change="reminderSecond"' + (offsets.length > 1 ? ' checked' : '') +
        '> Повторно за <input type="number" name="second" min="1" max="1440" value="' + (offsets[1] ?? 5) + '"' +
        (offsets.length > 1 ? '' : ' disabled') + '> мин.</label></div>' +
        '<p class="note">Только для вас на этом компьютере. Организатору не отправляется. Настройка серии заменяет личные исключения её отдельных встреч.</p>' +
        '<p class="warning" data-form-error></p><div class="row">' + button('Отмена', 'closeDialog') +
        '<span class="spacer"></span><button class="primary" type="submit">Сохранить</button></div></form>');
    const control = dialog.querySelector('.scope-select');
    if (control) control.name = 'scope';
}

function colorDialog(id, isCalendar = false, scope = 'occurrence') {
    const meeting = isCalendar ? null : findMeeting(id);
    const calendar = isCalendar ? calendarOf(id) : null;
    if (!meeting && !calendar) return;
    const action = isCalendar ? 'applyCalendarColor' : 'applyMeetingColor';
    const type = isCalendar ? 'календаря' : 'встречи';
    const selected = isCalendar ? calendar.color : state.colors?.[scope === 'series' ? meeting.seriesID : meeting.id];
    openDialog('<div class="stack"><h2 id="dialog-title">Цвет ' + type + '</h2><p>' + html(calendar?.name || meeting.title) + '</p>' +
        (meeting && recurrence(meeting) ? settingRow('Применить к',
            select('Применить к', [['occurrence', 'Этой встрече'], ['series', 'Всей серии']], scope, 'colorScope', { id })) : '') +
        '<div class="palette">' + palette.map(color => '<button type="button" style="--tint:' + color + '" aria-label="' + color +
            '" aria-pressed="' + (selected?.toUpperCase() === color) + '" data-action="' + action + '" data-payload="' +
            encoded({ id, scope, color }) + '"></button>').join('') + '</div><div class="row">' +
        button('По умолчанию', action, { id, scope, color: '' }) + '<span class="spacer"></span>' +
        button('Готово', 'closeDialog') + '</div></div>');
}

function openContext(content, point) {
    contextMenu.innerHTML = '<div class="popover context-menu stack" role="group" aria-label="Действия">' + content + '</div>';
    const panel = contextMenu.firstElementChild;
    const rect = panel.getBoundingClientRect();
    panel.style.left = Math.max(6, Math.min(point.x, innerWidth - rect.width - 6)) + 'px';
    panel.style.top = Math.max(6, Math.min(point.y, innerHeight - rect.height - 6)) + 'px';
    if (point.keyboard) panel.querySelector('button:enabled')?.focus({ preventScroll: true });
}

function closeContext() {
    contextMenu.replaceChildren();
}

function meetingMenu(meeting, point) {
    const id = meeting.id;
    const count = (meeting.end - currentTime()) / minute;
    const pinned = pinnedMeeting(meeting);
    const entries = [];
    entries.push(button(isEventPage(meeting.sourceURL) ? 'Редактировать в браузере' : 'Открыть день в Яндексе', 'edit', { id }, { glyph: 'out', className: 'plain' }));
    if (meeting.link || pinned) entries.push(button(pinned ? 'Открепить' : 'Закрепить', 'togglePin', { id }, { glyph: 'pin', className: 'plain' }));
    entries.push(button('Цвет встречи', 'meetingColor', { id }, { glyph: 'color', className: 'plain' }));
    if (!meeting.cancelled && !meeting.allDay && count > 0) {
        entries.push('<hr><span class="note" style="padding-inline:6px">Напомнить позже</span>');
        entries.push(button('Через 5 минут', 'snooze', { id, minutes: 5 }, { glyph: 'clock', className: 'plain', disabled: count <= 5 }));
        entries.push(button('Через 10 минут', 'snooze', { id, minutes: 10 }, { glyph: 'clock', className: 'plain', disabled: count <= 10 }));
        entries.push(button('В начале встречи', 'snooze', { id, atStart: true }, { glyph: 'clock', className: 'plain', disabled: meeting.start <= currentTime() }));
    }
    openContext(entries.join(''), point);
}

function planSlot({ start, end }) {
    const now = currentTime();
    const rounded = Math.ceil(Math.max(now, start) / (15 * minute)) * 15 * minute;
    const available = freeSlots(startOfDay(start), activeVisibleMeetings()).some(([from, to]) => rounded >= from && rounded + 30 * minute <= to);
    if (!available || rounded + 30 * minute > end) {
        notice('Свободное окно изменилось. Проверьте расписание и выберите время заново.');
        return;
    }
    createEvent({ start: rounded, end: rounded + 30 * minute });
}

function createEvent(payload) {
    if (activeAccounts().length > 1) {
        confirmAction('Создать событие в Яндексе', 'Выберите нужную почту в Яндекс Календаре после открытия браузера.',
            { type: 'create', payload }, 'Открыть Яндекс Календарь');
    } else {
        void invoke('create', payload);
    }
}

function anchorPoint(element) {
    const rect = element.getBoundingClientRect();
    return { x: rect.left, y: rect.bottom + 4, keyboard: element.matches(':focus-visible') };
}

function setSetting(key, value) {
    return invoke('settings', { values: { [key]: value } });
}

const actions = {
    navigate: ({ date, summary }) => navigate(date, { summary }),
    move: ({ offset }) => navigate(mode === 'day' || mode === 'week' ?
        addDays(anchor, offset * (mode === 'day' ? 1 : 7)) : addMonths(anchor, offset)),
    daySummary: ({ date, navigate: move }) => {
        if (move) { navigate(date, { summary: true }); return; }
        selectedDay = date;
        selectedId = '';
        inspector = true;
        compactSidebar = false;
        popover = '';
        render();
    },
    selectMeeting: ({ id, date }) => selectMeeting(id, date),
    selectConflict: ({ id }) => {
        const meeting = findMeeting(id);
        if (!meeting) return;
        if (!matches(meeting, filter)) filter = '';
        scrollIntent = 'event';
        selectMeeting(id, selectedDay);
    },
    mode: ({ mode: value }) => {
        if (value === mode) return;
        mode = value;
        anchor = selectedDay;
        localStorage.setItem('calendarAnchor', String(anchor));
        scrollIntent = selectedId ? 'event' : 'period';
        render();
        loadCalendar();
        void setSetting('calendarView', value);
    },
    sidebar: () => {
        if (lastCompact) {
            compactSidebar = !compactSidebar;
            if (compactSidebar) closeInspector();
        } else {
            sidebar = !sidebar;
            localStorage.setItem('calendarSidebar', String(sidebar));
        }
        popover = '';
        render();
    },
    collapseAccount: ({ login }) => {
        if (collapsed.has(login)) collapsed.delete(login);
        else collapsed.add(login);
        render();
    },
    inspector: () => {
        if (inspector) closeInspector();
        else inspector = true;
        compactSidebar = false;
        popover = '';
        render();
    },
    closeInspector: () => { closeInspector(); render(); },
    popover: ({ name }) => {
        popover = popover === name ? '' : name;
        if (popover === 'date') miniMonth = anchor;
        compactSidebar = false;
        if (lastCompact) closeInspector();
        render();
    },
    miniMove: ({ offset }) => { miniMonth = addMonths(miniMonth, offset); render(); },
    openSearch: () => {
        popover = '';
        compactSidebar = false;
        if (lastCompact) closeInspector();
        render();
        return invoke('open', { view: 'search', query: filter });
    },
    refreshCalendar: () => loadCalendar(true),
    focusCalendar: async ({ id }) => {
        const result = await invoke('open', { view: 'calendar', meeting: id });
        if (view === 'search' && result.ok !== false) void invoke('close');
    },
    createEvent,
    freeSlot: planSlot,
    settingsPage: ({ page: target }) => { page = target; render({ preserveForms: false }); },
    confirmCacheClear: ({ login }) => {
        const subject = login ? 'аккаунта «' + accountName(login) + '»' : 'всех аккаунтов';
        confirmAction('Очистить кэш календаря?', 'Сохранённые встречи ' + subject +
            ' будут удалены с этого компьютера. Настройки, пароли, закрепления и личные напоминания сохранятся.',
            { type: 'clearCalendarCache', payload: { login } }, login ? 'Очистить кэш' : 'Очистить весь кэш');
    },
    newAccount: () => openDialog(accountForm(null, true)),
    editAccount: ({ login }) => openDialog(accountForm(profile(login), true)),
    accountMenu: ({ login }, element) => {
        const account = profile(login);
        openContext(button('Изменить…', 'editAccount', { login }, { className: 'plain' }) +
            (login !== state.primaryLogin && account.active !== false ?
                button('Сделать основным', 'account', { login, primary: true }, { className: 'plain' }) : '') + '<hr>' +
            button('Удалить аккаунт…', 'confirmAccountRemoval', { login }, { className: 'plain' }), anchorPoint(element));
    },
    confirmAccountRemoval: ({ login }) => confirmAction('Удалить аккаунт?', 'Пароль и локальные данные аккаунта ' + login +
        ' будут удалены с этого компьютера.', { type: 'disconnect', payload: { login } }, 'Удалить'),
    settingsMenuMode: (_, element) => openContext(
        [['currentAndUpcoming', 'Текущие и предстоящие'], ['allToday', 'Все встречи сегодня'],
            ['upcomingOnly', 'Только предстоящие'], ['currentOnly', 'Только текущие']]
            .map(([value, label]) => button(label, 'chooseMenuMode', { value }, { className: 'plain', pressed: state.settings.menuMeetingsMode === value })).join(''),
        anchorPoint(element)),
    chooseMenuMode: ({ value }) => setSetting('menuMeetingsMode', value),
    testNotification: async () => {
        const result = await invoke('testNotification');
        if (result.ok !== false) notice('Тестовое уведомление через 3 секунды');
    },
    calendarColor: ({ id }) => colorDialog(id, true),
    meetingColor: ({ id }) => colorDialog(id),
    applyCalendarColor: async ({ id, color }) => {
        if ((await invoke('calendar', { id, color })).ok !== false) dialog.close();
    },
    applyMeetingColor: async ({ id, scope, color }) => {
        if ((await invoke('color', { id, scope, color })).ok !== false) dialog.close();
    },
    reminderEditor: ({ id }) => {
        const meeting = findMeeting(id);
        if (meeting) reminderDialog(meeting);
    },
    eventMenu: ({ id }, element) => {
        const meeting = findMeeting(id);
        if (meeting) meetingMenu(meeting, anchorPoint(element));
    },
    copyLink: async ({ url }) => {
        const result = await invoke('copyLink', { url });
        if (result.ok) notice('Ссылка скопирована');
    },
    togglePin: async ({ id }) => {
        const meeting = findMeeting(id);
        if (!meeting?.link) return;
        const pin = pinnedMeeting(meeting);
        const result = await invoke('pin', pin ? { id: pin.id, login: pin.login, remove: true } :
            { login: meeting.accountLogin || state.primaryLogin, title: meeting.title, url: meeting.link });
        if (result.ok !== false) notice(pin ? 'Убрано из закреплённых' : 'Закреплено в области уведомлений');
    },
    editPin: ({ id }) => { pinEdit = id; render({ preserveForms: false }); focusPinName(); },
    removePin: async ({ id, login }) => {
        if (pinEdit === id) pinEdit = undefined;
        await invoke('pin', { id, login, remove: true });
    },
    resetPin: () => { pinEdit = undefined; render({ preserveForms: false }); focusPinName(); },
    searchMeeting: ({ id }) => { searchId = id; render({ preserveFocus: false }); },
    searchBack: () => { searchId = ''; render({ preserveFocus: false }); focusSearch(); },
    clearQuery: () => { searchQuery = ''; highlighted = -1; render({ preserveFocus: false }); focusSearch(); },
    searchPeriod: () => openDialog('<form class="stack" data-form="searchPeriod"><h2 id="dialog-title">Период поиска</h2>' +
        '<label class="field">С<input type="date" name="from" value="' + civilDate(searchFrom) + '" required></label>' +
        '<label class="field">По<input type="date" name="to" value="' + civilDate(addDays(searchTo, -1)) +
        '" required></label><p class="note">Можно выбрать период до трёх лет.</p><p class="warning" data-form-error role="alert"></p>' +
        '<div class="row">' + button('Отмена', 'closeDialog') + '<span class="spacer"></span><button class="primary" type="submit">Загрузить</button></div></form>'),
    activityFilter: ({ unread }) => { unreadOnly = unread; render(); },
    activityMenu: (_, element) => openContext(
        button('Отметить всё прочитанным', 'markActivity', {}, { className: 'plain', disabled: !state.activity.some(entry => entry.unread) }) +
        button('Очистить историю', 'confirmClear', {}, { className: 'plain', disabled: !state.activity.length }), anchorPoint(element)),
    confirmClear: () => confirmAction('Очистить историю?', 'Все сохранённые изменения расписания будут удалены.',
        { type: 'clearActivity', payload: {} }, 'Очистить'),
    openActivity: async ({ id, meeting }) => {
        await invoke('markActivity', { id });
        return invoke('open', { view: 'meeting', meeting });
    },
    focusActivity: async ({ id, meeting }) => {
        await invoke('markActivity', { id });
        return invoke('open', { view: 'calendar', meeting });
    },
    trayMenu: (_, element) => openContext(button('Выход', 'quit', {}, { className: 'plain' }), anchorPoint(element)),
    closeDialog: () => dialog.close()
};

function focusSearch() {
    app.querySelector('#search-query')?.focus();
}

function focusPinName() {
    app.querySelector('form[data-form=pin] input[name=title]')?.focus();
}

document.addEventListener('click', event => {
    const element = event.target.closest('[data-action]');
    if (!contextMenu.contains(event.target) || element) closeContext();
    if (!element) {
        if (popover && !event.target.closest('.popover')) { popover = ''; render(); }
        return;
    }
    if (event.detail > 0) element.blur();
    const action = element.dataset.action;
    const payload = decodePayload(element);
    if (actions[action]) void actions[action](payload, element);
    else void invoke(action, payload);
});

document.addEventListener('contextmenu', event => {
    const id = event.target.closest('[data-meeting]')?.dataset.meeting;
    if (!id) return;
    const meeting = findMeeting(id);
    if (!meeting) return;
    event.preventDefault();
    meetingMenu(meeting, { x: event.clientX, y: event.clientY });
});

document.addEventListener('dblclick', event => {
    if (!event.target.classList.contains('time-column')) return;
    const { date, minute: first } = event.target.dataset;
    const rect = event.target.getBoundingClientRect();
    const offset = (event.clientY - rect.top) * 60 / 52 + Number(first);
    createEvent({ start: atMinute(Number(date), Math.min(1439, Math.floor(offset / 15) * 15)) });
});

document.addEventListener('input', event => {
    if (event.target.dataset.input === 'filter') {
        filter = event.target.value;
        render();
    } else if (event.target.dataset.input === 'searchQuery') {
        searchQuery = event.target.value;
        highlighted = -1;
        render();
    }
});

document.addEventListener('change', event => {
    const element = event.target;
    const payload = decodePayload(element);
    const value = element.type === 'checkbox' ? element.checked : element.value;
    switch (element.dataset.change) {
        case 'mode':
            actions.mode({ mode: value });
            break;
        case 'declined':
            showDeclined = value;
            localStorage.setItem('showDeclined', String(showDeclined));
            render();
            break;
        case 'setting':
            void setSetting(payload.key, value);
            break;
        case 'settingNumber':
            if (value !== '' && element.validity.valid) void setSetting(payload.key, Number(value));
            else render();
            break;
        case 'overviewTime': {
            if (!value) break;
            const [dailyOverviewHour, dailyOverviewMinute] = value.split(':').map(Number);
            void invoke('settings', { values: { dailyOverviewHour, dailyOverviewMinute } });
            break;
        }
        case 'account':
        case 'calendar': {
            const identity = payload.id ? { id: payload.id } : { login: payload.login };
            void invoke(element.dataset.change, { ...identity, [payload.key]: value });
            break;
        }
        case 'calendarTint':
            void invoke('calendar', { id: payload.id, color: value });
            break;
        case 'pinLogin':
            pinLogin = value;
            pinEdit = undefined;
            render({ preserveForms: false });
            focusPinName();
            break;
        case 'colorScope':
            colorDialog(payload.id, false, value);
            break;
        case 'reminderScope': {
            const meeting = findMeeting(payload.id);
            if (meeting) reminderDialog(meeting, value);
            break;
        }
        case 'reminderKind':
            element.form.querySelector('[data-reminder-custom]').hidden = value !== 'custom';
            break;
        case 'reminderSecond':
            element.form.elements.second.disabled = !value;
            break;
    }
});

const busyForms = new Set();

document.addEventListener('submit', async event => {
    event.preventDefault();
    const form = event.target;
    const formType = form.dataset.form;
    if (busyForms.has(formType)) return;
    const raw = Object.fromEntries(new FormData(form, event.submitter));
    const data = decodePayload(form);
    const inDialog = dialog.contains(form);
    let result;
    if (formType === 'searchPeriod') {
        const start = parseCivil(raw.from);
        const end = addDays(parseCivil(raw.to), 1);
        if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start || end > addMonths(start, 36) + day) {
            form.querySelector('[data-form-error]').textContent = 'Выберите даты по порядку и период до трёх лет.';
            return;
        }
        searchFrom = start;
        searchTo = end;
        highlighted = -1;
        dialog.close();
        void runSearch();
        focusSearch();
        return;
    }
    const errorElement = form.querySelector('[data-form-error]');
    if (errorElement) errorElement.textContent = '';
    busyForms.add(formType);
    for (const element of form.querySelectorAll('button[type=submit]')) element.disabled = true;
    if (formType === 'account') {
        raw.login = raw.login.trim().toLowerCase();
        raw.label = raw.label.trim();
        raw.zone = raw.zone.trim();
        const existing = profile(raw.login);
        if (existing && !inDialog) {
            result = { ok: false, error: 'Этот аккаунт уже добавлен. Его можно изменить в списке аккаунтов.' };
        } else if (existing && !raw.password && raw.zone === existing.settings?.zone && raw.verify !== 'true') {
            result = await invoke('account', { login: raw.login, label: raw.label }, { quiet: true });
        } else {
            result = await invoke('connect', raw, { quiet: true });
        }
        if (result.ok !== false) initialDraft = {};
    } else if (formType === 'pin') {
        result = await invoke('pin', { id: pinEdit, login: pinLogin ?? state.primaryLogin ?? '', title: raw.title.trim(), url: raw.url.trim() }, { quiet: true });
        if (result.ok !== false) {
            pinEdit = undefined;
            render({ preserveForms: false });
            focusPinName();
        }
    } else if (formType === 'reminder') {
        const value = raw.kind === 'default' ? null : raw.kind === 'muted' ? { muted: true } :
            { minutes: [Number(raw.first), ...(raw.secondEnabled ? [Number(raw.second)] : [])] };
        result = await invoke('reminder', { id: data.id, scope: raw.scope || 'occurrence', value }, { quiet: true });
    } else if (formType === 'confirm') {
        result = await invoke(data.type, data.payload, { quiet: true });
        if (data.type === 'clearCalendarCache' && result.ok) {
            cacheFeedback = result.releasedBytes > 0 ?
                'Кэш очищен. Освобождено ' + cacheSize(result.releasedBytes) + '.' : 'Кэш очищен.';
            render();
        }
    }
    busyForms.delete(formType);
    const current = [...(inDialog ? dialog : app).querySelectorAll('form')].find(element => element.dataset.form === formType);
    if (result?.ok === false && current) current.querySelector('[data-form-error]').textContent = result.error;
    if (result?.ok !== false && inDialog) dialog.close();
    if (current) for (const element of current.querySelectorAll('button[type=submit]')) element.disabled = false;
});

document.addEventListener('keydown', event => {
    if (event.isComposing) return;
    const key = event.key;
    if (key === 'Escape') {
        if (dialog.open) return;
        if (contextMenu.childElementCount) closeContext();
        else if (popover) { popover = ''; render(); }
        else if (view === 'calendar') {
            compactSidebar = false;
            closeInspector();
            render();
        } else if (view === 'search' && searchId) actions.searchBack();
        else if (view === 'search' || view === 'tray') void invoke('close');
        return;
    }
    if ((event.ctrlKey || event.metaKey) && !dialog.open) {
        const lower = key.toLowerCase();
        if (key === ',') {
            event.preventDefault();
            void invoke('open', { view: 'settings' });
        } else if (view === 'calendar' && ['f', 't', 'n', 'r'].includes(lower)) {
            event.preventDefault();
            if (lower === 'f') void actions.openSearch();
            else if (lower === 't') navigate(currentTime());
            else if (lower === 'n') createEvent({ start: defaultStart(selectedDay) });
            else loadCalendar(true);
        }
    }
    if (event.target.id !== 'search-query' || !['ArrowDown', 'ArrowUp', 'Enter'].includes(key)) return;
    const meetings = searchMatches();
    if (!meetings.length) return;
    event.preventDefault();
    if (key === 'Enter') {
        actions.searchMeeting({ id: meetings[Math.max(0, highlighted)].id });
    } else {
        highlighted = highlighted < 0 && key === 'ArrowUp' ? meetings.length - 1 :
            Math.min(meetings.length - 1, Math.max(0, highlighted + (key === 'ArrowDown' ? 1 : -1)));
        render();
        app.querySelector('.result-row.highlighted')?.scrollIntoView({ block: 'nearest' });
    }
});

window.addEventListener('resize', () => {
    if (view !== 'calendar') return;
    const compact = matchMedia('(max-width:1199px)').matches;
    if (compact !== lastCompact || mode === 'month') {
        if (compact !== lastCompact) {
            compactSidebar = false;
            popover = '';
            lastCompact = compact;
        }
        render();
    }
});

async function start() {
    if (!api) {
        app.textContent = 'Откройте CalendarBar из установленного приложения.';
        return;
    }
    try {
        api.onState(applyState);
        applyState(await api.getState());
        if (view === 'search') { focusSearch(); void runSearch(); }
        if (view === 'pinned') focusPinName();
        if (view === 'calendar' || view === 'tray') setInterval(() => {
            if (!document.hidden && !dialog.open && !contextMenu.childElementCount &&
                !(document.activeElement instanceof HTMLInputElement)) render();
        }, 15_000);
    } catch (error) {
        app.textContent = 'Не удалось загрузить CalendarBar. ' + error.message;
    }
}

void start();
