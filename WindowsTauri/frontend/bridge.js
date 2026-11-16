'use strict';

(() => {
    const params = new URLSearchParams(location.search);
    const allowedViews = new Set(['calendar', 'meeting', 'search', 'tray', 'settings']);
    const requestedView = params.get('view');
    const view = allowedViews.has(requestedView) ? requestedView : 'calendar';
    const gallery = params.get('gallery') === '1';
    document.documentElement.classList.toggle('interactive-preview', !gallery);
    if (gallery) {
        const captureTime = +new Date(2026, 10, 18, 10, 33);
        Date.now = () => captureTime;
    }
    const host = window.calendarBarPreviewHost ?? window.__TAURI__;
    const invokeHost = host?.core?.invoke ?? host?.invoke;
    const listenHost = host?.event?.listen ?? host?.listen;

    const jsonReply = (ok, error) => error ? { ok, error } : { ok };
    const unsupported = () => jsonReply(false, 'В этой сборке используются демонстрационные данные.');
    const listeners = new Set();
    const now = Date.now();
    const limits = previewFixture.limits(now);
    let focusMeeting = previewFixture.meeting(params.get('meeting'), now);
    let focusQuery = params.get('query') ?? undefined;
    let focusToken = 1;
    let range = previewFixture.initialRange(view, now, focusMeeting);
    let meetings = previewFixture.meetings(range.from, range.to, now);
    let accounts = gallery && view === 'tray' ? [previewFixture.accounts[0]] : previewFixture.accounts;
    let settings = {
        calendarView: 'week', workdayOnly: true, workdayStartHour: 9, workdayStartMinute: 30,
        workdayEndHour: 18, workdayEndMinute: 15, menuCountdownWindow: 30
    };
    let appearance = gallery ? 'dark' : 'system';
    let hiddenLast = {};

    function state() {
        const coverage = { from: Math.max(limits.from, range.from), to: Math.min(limits.to, range.to) };
        return {
            version: previewVersion, appearance, settings, accounts, meetings,
            primaryLogin: previewFixture.primaryLogin, focusMeeting, focusQuery, focusToken,
            coverage: coverage.from < coverage.to ? [coverage] : [],
            pins: [{ id: 'demo-room', title: 'Комната команды', url: 'https://example.test/demo-meeting', login: previewFixture.primaryLogin }],
            cacheBytes: Object.fromEntries(accounts.map(({ login }, index) => [login, index ? 240_000 : 1_250_000])),
            activity: [], snoozes: [], hiddenLast, syncing: false, lastSync: now
        };
    }

    function publish() {
        const snapshot = state();
        for (const listener of listeners) listener(snapshot);
    }

    function applyNavigation({ meeting, query } = {}) {
        focusMeeting = previewFixture.meeting(meeting, now);
        focusQuery = typeof query === 'string' ? query : undefined;
        focusToken++;
        if (view === 'meeting' && focusMeeting) {
            range = previewFixture.initialRange(view, now, focusMeeting);
            meetings = previewFixture.meetings(range.from, range.to, now);
        }
        publish();
    }

    if (listenHost) {
        Promise.resolve(listenHost('preview-navigation', ({ payload }) => applyNavigation(payload)))
            .catch(error => console.error('CalendarBar preview navigation:', error));
    }

    async function nativeAction(command, payload, browserFallback) {
        if (!invokeHost) return browserFallback?.() ?? jsonReply(true);
        await invokeHost(command, payload);
        return jsonReply(true);
    }

    function navigateBrowser(payload) {
        const target = new URL(location.href);
        target.search = new URLSearchParams(Object.entries(payload).filter(([, value]) => value != null));
        location.assign(target);
        return jsonReply(true);
    }

    function load({ from, to }) {
        if (!Number.isFinite(from) || !Number.isFinite(to) || !(from < to)) {
            return jsonReply(false, 'Выберите корректный период.');
        }
        if (range.from === from && range.to === to) return jsonReply(true);
        range = { from, to };
        meetings = previewFixture.meetings(from, to, now);
        publish();
        return jsonReply(true);
    }

    function changeSetting({ values } = {}) {
        if ('calendarView' in (values ?? {})) {
            const mode = values.calendarView;
            if (['day', 'week', 'month', 'agenda'].includes(mode)) settings = { ...settings, calendarView: mode };
        }
        if (typeof values?.workdayOnly === 'boolean') settings = { ...settings, workdayOnly: values.workdayOnly };
        if (['system', 'light', 'dark'].includes(values?.appearance)) appearance = values.appearance;
        for (const [key, min, max] of [
            ['workdayStartHour', 0, 23], ['workdayStartMinute', 0, 59],
            ['workdayEndHour', 0, 24], ['workdayEndMinute', 0, 59], ['menuCountdownWindow', 0, 180]
        ]) {
            if (Number.isInteger(values?.[key]) && values[key] >= min && values[key] <= max) {
                settings = { ...settings, [key]: values[key] };
            }
        }
        publish();
        return jsonReply(true);
    }

    async function action(type, payload = {}) {
        switch (type) {
        case 'open': {
            if (!allowedViews.has(payload.view)) return unsupported();
            const target = { view: payload.view, meeting: payload.meeting ?? null, query: payload.query ?? null };
            return nativeAction('open_view', target, () => navigateBrowser(target));
        }
        case 'close':
            return nativeAction('close_view', {}, () => navigateBrowser({ view: 'calendar' }));
        case 'fitTray':
            if (view !== 'tray') return unsupported();
            return nativeAction('fit_tray', { height: Math.round(payload.height) });
        case 'quit':
            return nativeAction('quit_preview');
        case 'load':
        case 'search':
            return load(payload);
        case 'sync':
            return Number.isFinite(payload.from) && Number.isFinite(payload.to) ? load(payload) : jsonReply(true);
        case 'settings':
            return changeSetting(payload);
        case 'account':
            if (typeof payload.visible !== 'boolean') return unsupported();
            accounts = accounts.map(account => account.login === payload.login ? { ...account, visible: payload.visible } : account);
            publish();
            return jsonReply(true);
        case 'calendar': {
            const color = payload.color;
            const visibility = typeof payload.visible === 'boolean';
            if (!visibility && color !== '' && !/^#[\da-f]{6}$/i.test(color ?? '')) return unsupported();
            const change = visibility ? { visible: payload.visible } : { color };
            accounts = accounts.map(account => ({ ...account, calendars: account.calendars.map(calendar =>
                calendar.id === payload.id ? { ...calendar, ...change } : calendar) }));
            publish();
            return jsonReply(true);
        }
        case 'hideLast': {
            const meeting = previewFixture.meeting(payload.id, now);
            if (!meeting) return unsupported();
            hiddenLast = { ...hiddenLast, [meeting.accountLogin]: payload.hidden ? meeting.id : null };
            publish();
            return jsonReply(true);
        }
        default:
            return unsupported();
        }
    }

    window.calendarBar = {
        getState: async () => state(),
        action: async (type, payload) => {
            try { return await action(type, payload); }
            catch (error) {
                return jsonReply(false, error instanceof Error ? error.message : String(error));
            }
        },
        onState(listener) {
            listeners.add(listener);
            return () => listeners.delete(listener);
        }
    };
})();
