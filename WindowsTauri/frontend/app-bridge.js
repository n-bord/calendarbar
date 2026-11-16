'use strict';

(() => {
    const { core, event, webviewWindow } = window.__TAURI__;
    const target = webviewWindow.getCurrentWebviewWindow().label;
    // Register early so an update between getState() and rendering is delivered.
    const listeners = new Set();
    const ready = event.listen('calendarbar-update', ({ payload }) => {
        for (const listener of listeners) listener(payload);
    }, { target });
    window.calendarBar = {
        async getState() {
            await ready;
            return core.invoke('get_state');
        },
        action: (type, payload = {}) => core.invoke('run_action', { action: type, payload }),
        onState(listener) {
            listeners.add(listener);
            return () => listeners.delete(listener);
        }
    };
})();
