'use strict';

const previewFixture = (() => {
    const minute = 60_000;
    const primaryLogin = 'team@example.test';
    const secondaryLogin = 'personal@example.test';
    const accounts = [
        { login: primaryLogin, label: 'Команда', active: true, visible: true, calendars: [
            { id: 'projects', name: 'Проект Север', visible: true, listed: true, color: '#378BE7' },
            { id: 'team', name: 'Командный календарь', visible: true, listed: true, color: '#1ACB64' }
        ] },
        { login: secondaryLogin, label: 'Личный', active: true, visible: true, calendars: [
            { id: 'personal', name: 'Личные планы', visible: true, listed: true, color: '#A95FD3' }
        ] }
    ];
    const slots = [
        { time: 9 * 60 + 30, duration: 30, calendar: 'team', title: 'Планирование недели', topics: ['план на день', 'состояние задач', 'зависимости', 'следующие шаги'] },
        { time: 10 * 60 + 30, duration: 50, calendar: 'projects', title: 'Дизайн-ревью', topics: ['прототип', 'аналитика', 'дизайн', 'план релиза', 'обратная связь'] },
        { time: 12 * 60, duration: 45, calendar: 'projects', title: 'Рабочая встреча', topics: ['новая версия', 'приоритеты', 'бюджет', 'регрессии', 'итоги недели'] },
        { time: 12 * 60 + 30, duration: 45, calendar: 'team', title: 'Обзор задач', topics: ['макеты', 'тесты', 'документация', 'план работ'] },
        { time: 15 * 60, duration: 45, calendar: 'projects', title: 'Демо проекта', topics: ['демо', 'сборка', 'обновление', 'проверка сценариев'] },
        { time: 17 * 60, duration: 40, calendar: 'personal', title: 'Личное время', topics: ['запись', 'планирование', 'встреча', 'занятие'] }
    ];
    const typeById = Object.fromEntries(accounts.flatMap(account =>
        account.calendars.map(calendar => [calendar.id, { account, calendar }])));
    const attendees = [
        { name: 'Анна Орлова', email: 'anna@example.test', response: 'ACCEPTED', optional: false },
        { name: 'Михаил Соколов', email: 'mikhail@example.test', response: 'TENTATIVE', optional: false },
        { name: 'Лена Иванова', email: 'lena@example.test', response: 'ACCEPTED', optional: false },
        { name: 'Олег Петров', email: 'oleg@example.test', response: 'NEEDS-ACTION', optional: true }
    ];

    function midnight(value) {
        const date = new Date(value);
        date.setHours(0, 0, 0, 0);
        return +date;
    }

    function addDays(value, n) {
        const date = new Date(value);
        date.setDate(date.getDate() + n);
        return +date;
    }

    function dateKey(value) {
        const date = new Date(value);
        return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0'),
            String(date.getDate()).padStart(2, '0')].join('-');
    }

    function atMinute(value, valueInMinutes) {
        const date = new Date(value);
        date.setHours(0, valueInMinutes, 0, 0);
        return +date;
    }

    // Two years of past weekdays plus enough future data for the calendar and tray.
    function limits(now) {
        const today = midnight(now);
        const past = new Date(today);
        past.setFullYear(past.getFullYear() - 2);
        return { from: +past, to: addDays(today, 100) };
    }

    function dayMeetings(day) {
        const date = new Date(day);
        const weekday = date.getDay();
        const seed = date.getFullYear() * 372 + date.getMonth() * 31 + date.getDate();
        const isWorkday = weekday >= 1 && weekday <= 5;
        const dateID = dateKey(day);
        const list = [];

        for (const [index, slot] of slots.entries()) {
            if (!isWorkday && (index !== 5 || weekday !== 6)) continue;
            if (index >= 3 && seed % 4 === index - 3) continue;
            const { account, calendar } = typeById[slot.calendar];
            const topic = slot.topics[seed % slot.topics.length];
            const response = seed % 11 === 0 ? 'TENTATIVE' : seed % 7 === 0 ? 'NEEDS-ACTION' : 'ACCEPTED';
            const start = atMinute(day, slot.time + (index > 0 && seed % 5 === 0 ? 15 : 0));
            list.push({
                id: dateID + '/' + index, seriesID: 'demo-series-' + index, accountLogin: account.login,
                calendarID: calendar.id, calendarName: calendar.name, title: slot.title,
                start, end: start + slot.duration * minute, allDay: false,
                details: 'Обсудить ' + topic + '. Подготовить вопросы и проверить итоговые материалы к встрече.',
                location: index < 5 ? 'Онлайн' : 'Вне офиса',
                organizer: index < 5 ? 'anna@example.test' : secondaryLogin,
                attendees: index < 5 ? [{ name: 'Вы', email: account.login, response, optional: false }, ...attendees] : [],
                link: index < 5 ? 'https://example.test/demo-meeting' : null,
                isFree: index === 5 && seed % 5 === 0,
                recurrenceRule: index === 0 ? 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR' : null
            });
        }
        if (weekday === 3) {
            const calendar = typeById.projects.calendar;
            const end = addDays(day, 1);
            list.push({
                id: dateID + '/6', seriesID: 'demo-series-all-day', accountLogin: primaryLogin,
                calendarID: calendar.id, calendarName: calendar.name, title: 'Срок сдачи материалов',
                start: day, end, allDay: true, allDayDates: { start: dateID, end: dateKey(end) },
                organizer: primaryLogin, isFree: true, attendees: []
            });
        }
        return list;
    }

    function meetings(from, to, now) {
        const available = limits(now);
        const first = Math.max(midnight(from), available.from);
        const end = Math.min(to, available.to);
        const list = [];
        for (let day = first; day < end; day = addDays(day, 1)) {
            for (const meeting of dayMeetings(day)) {
                if (meeting.start < to && meeting.end > from) list.push(meeting);
            }
        }
        return list.sort((first, second) => first.start - second.start);
    }

    function meeting(id, now) {
        const match = /^(\d{4}-\d{2}-\d{2})\/[0-6]$/.exec(id ?? '');
        if (!match) return null;
        const day = +new Date(match[1] + 'T00:00:00');
        const { from, to } = limits(now);
        if (!(day >= from && day < to)) return null;
        return dayMeetings(day).find(event => event.id === id) ?? null;
    }

    function initialRange(view, now, selected) {
        if (view === 'meeting' && selected) {
            const today = midnight(selected.start);
            return { from: today, to: addDays(today, 1) };
        }
        const today = midnight(now);
        if (view === 'tray') return { from: addDays(today, -1), to: addDays(today, 15) };
        if (view === 'search') return { from: today, to: today };
        return { from: addDays(today, -6), to: addDays(today, 7) };
    }

    return { primaryLogin, accounts, limits, meetings, meeting, initialRange };
})();

if (typeof module === 'object' && module.exports) module.exports = previewFixture;
