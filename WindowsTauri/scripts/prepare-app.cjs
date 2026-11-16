'use strict';

const fs = require('node:fs');
const path = require('node:path');
const project = path.resolve(__dirname, '..');
const upstream = path.resolve(project, '../Windows/src');
const output = path.join(project, 'web-app');
const entry = fs.readFileSync(path.join(upstream, 'index.html'), 'utf8');
const scripts = '    <script src="ui.js" defer></script>';
if (!entry.includes(scripts) || !entry.includes("connect-src 'none'")) {
  throw new Error('The Windows renderer entry point has changed.');
}
fs.mkdirSync(output, { recursive: true });
for (const file of ['ui.js', 'styles.css']) {
  fs.copyFileSync(path.join(upstream, file), path.join(output, file));
}
fs.copyFileSync(path.join(project, 'frontend', 'app-bridge.js'), path.join(output, 'app-bridge.js'));
fs.writeFileSync(path.join(output, 'index.html'), entry
  .replace("connect-src 'none'", 'connect-src ipc: http://ipc.localhost')
  .replace(scripts, '    <script src="app-bridge.js" defer></script>\n' + scripts));
