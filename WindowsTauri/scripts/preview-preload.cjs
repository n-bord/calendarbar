'use strict';

const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('calendarBarPreviewHost', {
  invoke: (command, args) => ipcRenderer.invoke('preview:invoke', command, args),
  listen(event, listener) {
    if (event !== 'preview-navigation') throw new Error('Unknown preview event');
    const receive = (_ipcEvent, payload) => listener({ payload });
    ipcRenderer.on(event, receive);
    return Promise.resolve(() => ipcRenderer.removeListener(event, receive));
  }
});
