'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { spawn } = require('node:child_process');
const dependencies = path.join(__dirname, '../demo');
let executable;
try {
  executable = require(require.resolve('electron', { paths: [dependencies] }));
} catch {
  console.error('Сначала установите зависимости командой npm ci --prefix WindowsTauri/demo из корня репозитория.');
  process.exit(1);
}
const args = process.argv.slice(2);
const captureProfile = args.includes('--screenshots') ? fs.mkdtempSync(path.join(os.tmpdir(), 'calendarbar-demo-')) : null;
if (captureProfile) args.push('--capture-profile=' + captureProfile);
const child = spawn(executable, [path.join(__dirname, 'electron-preview.cjs'), ...args], {
  stdio: 'inherit'
});
child.on('spawn', () => console.log('Electron preview PID: ' + child.pid));
child.on('error', error => {
  console.error(error.message);
  if (captureProfile) fs.rmSync(captureProfile, { recursive: true, force: true });
  process.exitCode = 1;
});
child.on('exit', code => {
  if (captureProfile) fs.rmSync(captureProfile, { recursive: true, force: true });
  process.exitCode = code ?? 1;
});
