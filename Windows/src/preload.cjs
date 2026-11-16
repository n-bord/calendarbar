'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('calendarBar', {
  getState: () => ipcRenderer.invoke('calendarbar:state'),
  action: (type, payload) => ipcRenderer.invoke('calendarbar:action', type, payload),
  onState(listener) {
    const receive = (_event, state) => listener(state);
    ipcRenderer.on('calendarbar:update', receive);
    return () => ipcRenderer.removeListener('calendarbar:update', receive);
  }
});
