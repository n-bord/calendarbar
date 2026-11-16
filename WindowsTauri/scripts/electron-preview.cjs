'use strict';

const path = require('node:path');
const fs = require('node:fs');
const { app, BrowserWindow, Menu, Tray, ipcMain, nativeImage, screen, session } = require('electron');

const views = {
  calendar: ['CalendarBar · Electron Preview', 1240, 780, 820, 560],
  search: ['Поиск встреч · Electron Preview', 840, 645, 600, 460],
  meeting: ['Встреча · Electron Preview', 600, 650, 440, 440],
  settings: ['Настройки CalendarBar · Electron Preview', 800, 635, 720, 550],
  tray: ['CalendarBar · Electron Preview', 364, 280, 0, 0]
};
const windows = new Map();
const index = path.resolve(__dirname, '../web-dist/index.html');
const icon = path.resolve(__dirname, '../src-tauri/icons/icon.png');
const captureProfile = process.argv.find(arg => arg.startsWith('--capture-profile='))?.slice('--capture-profile='.length);
if (captureProfile) app.disableHardwareAcceleration();
let tray;
let trayHeight = views.tray[2];

function fitTray(window) {
  const bounds = tray.getBounds();
  const center = { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
  const work = screen.getDisplayNearestPoint(center).workArea;
  const width = Math.min(views.tray[1], work.width - 8);
  const height = Math.min(trayHeight, work.height - 12);
  const x = Math.max(work.x + 4, Math.min(center.x - width / 2, work.x + work.width - width - 4));
  const y = center.y >= work.y + work.height / 2 ? work.y + work.height - height - 6 : work.y + 6;
  window.setBounds({ x: Math.round(x), y: Math.round(y), width, height });
}

function openWindow(view, { meeting, query } = {}) {
  const previous = windows.get(view);
  if (previous) {
    if (view === 'tray') fitTray(previous);
    previous.show();
    if (meeting || query != null) previous.webContents.send('preview-navigation', { meeting, query });
    return;
  }
  const [title, width, height, minWidth, minHeight] = views[view];
  const popup = view === 'tray';
  const window = new BrowserWindow({
    title, width, height, minWidth, minHeight, icon, show: false, useContentSize: true, frame: !popup,
    resizable: !popup, skipTaskbar: popup, alwaysOnTop: popup, autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preview-preload.cjs'), contextIsolation: true, sandbox: true }
  });
  windows.set(view, window);
  window.setMenu(null);
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', event => event.preventDefault());
  window.once('ready-to-show', () => {
    if (popup) fitTray(window);
    window.show();
  });
  window.on('blur', () => { if (popup) window.hide(); });
  window.on('closed', () => windows.delete(view));
  const parameters = { view };
  if (meeting) parameters.meeting = meeting;
  if (query != null) parameters.query = query;
  void window.loadFile(index, { query: parameters });
}

async function saveScreenshots() {
  const output = path.resolve(__dirname, '../../docs/screenshots');
  const captures = [
    ['tray', views.tray[1], 565, '.tray-item.featured'],
    ['calendar', 1360, 684, '.inspector .details-content', { meeting: '2026-11-18/1' }],
    ['settings', 780, 516, '[data-action="settingsPage"]']
  ];
  const screenshots = [];
  for (const [view, width, height, selector, parameters] of captures) {
    const window = new BrowserWindow({
      width, height, show: false, frame: false, useContentSize: true,
      webPreferences: { contextIsolation: true, sandbox: true, backgroundThrottling: false, offscreen: true }
    });
    try {
      const contents = window.webContents;
      await window.loadFile(index, { query: { view, gallery: '1', ...parameters } });
      await contents.executeJavaScript(`
        (async () => {
          await document.fonts.ready;
          await new Promise(resolve => setTimeout(resolve, 60));
          if (!document.querySelector(${JSON.stringify(selector)})) {
            throw new Error('Demo view did not render: ' + document.body.innerText.slice(0, 400));
          }
          if (${JSON.stringify(view)} === 'settings') {
            [...document.querySelectorAll('[data-action="settingsPage"]')]
              .find(button => JSON.parse(button.dataset.payload).page === 'appearance').click();
            if (!document.querySelector('input[aria-label="Минуты начала"]')) {
              throw new Error('Workday settings did not render');
            }
            await new Promise(resolve => setTimeout(resolve, 60));
          }
        })()
      `);
      if (view === 'tray') {
        const actualHeight = await contents.executeJavaScript(`(() => {
          const app = document.querySelector('#app');
          const content = document.querySelector('.tray-sections');
          const chrome = app.clientHeight - content.clientHeight;
          return Math.ceil(chrome + content.firstElementChild.getBoundingClientRect().height);
        })()`);
        window.setContentSize(width, Math.min(height, actualHeight));
        await contents.executeJavaScript('new Promise(resolve => setTimeout(resolve, 60))');
      }
      const image = await contents.capturePage();
      if (image.isEmpty()) throw new Error('Unable to capture Windows preview: ' + view);
      screenshots.push([path.join(output, 'windows-' + view + '.png'), image.toPNG()]);
    } finally {
      window.destroy();
    }
  }
  fs.mkdirSync(output, { recursive: true });
  for (const [file, png] of screenshots) {
    fs.writeFileSync(file, png);
    console.log(file);
  }
}

app.setName('CalendarBar Electron Preview');
app.setPath('userData', captureProfile ?? path.join(app.getPath('appData'), 'CalendarBar Electron Benchmark'));
app.on('window-all-closed', () => {});
void app.whenReady().then(() => {
  session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  if (captureProfile) {
    void saveScreenshots().then(() => app.quit(), error => { console.error(error); app.exit(1); });
    return;
  }
  tray = new Tray(nativeImage.createFromPath(icon).resize({ width: 20, height: 20 }));
  tray.setToolTip('CalendarBar · Electron Preview');
  tray.on('click', () => {
    const popup = windows.get('tray');
    if (popup?.isVisible()) popup.hide();
    else openWindow('tray');
  });
  tray.on('right-click', () => tray.popUpContextMenu(Menu.buildFromTemplate([
    { label: 'Календарь', click: () => openWindow('calendar') },
    { label: 'Поиск встреч', click: () => openWindow('search') },
    { label: 'Настройки', click: () => openWindow('settings') },
    { label: 'Выход из прототипа', click: () => app.quit() }
  ])));
  ipcMain.handle('preview:invoke', (event, command, args = {}) => {
    const window = BrowserWindow.fromWebContents(event.sender);
    if (![...windows.values()].includes(window) || event.senderFrame !== event.sender.mainFrame) {
      throw new Error('Window unavailable');
    }
    const popup = window === windows.get('tray');
    switch (command) {
      case 'open_view':
        if (!['calendar', 'search', 'meeting', 'settings'].includes(args.view)) throw new Error('Window unavailable');
        openWindow(args.view, args);
        if (popup) window.hide();
        break;
      case 'close_view':
        if (popup) window.hide();
        else window.close();
        break;
      case 'fit_tray':
        if (popup && Number.isInteger(args.height)) {
          trayHeight = Math.min(565, Math.max(132, args.height));
          fitTray(window);
        }
        break;
      case 'quit_preview': app.quit(); break;
      default: throw new Error('Command unavailable');
    }
  });
  if (!process.argv.includes('--background')) {
    const view = process.argv.find(arg => arg.startsWith('--view='))?.slice('--view='.length);
    openWindow(Object.hasOwn(views, view) ? view : 'calendar');
  }
});
