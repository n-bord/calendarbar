'use strict';

const fs = require('node:fs');
const path = require('node:path');

const prototype = path.resolve(__dirname, '..');
const upstream = path.join(prototype, '..', 'Windows', 'src');
const source = path.join(prototype, 'frontend');
const output = path.join(prototype, 'web-dist');
const { version } = require('../package.json');

const index = fs.readFileSync(path.join(upstream, 'index.html'), 'utf8');
const scripts = '    <script src="ui.js" defer></script>';
const csp = "connect-src 'none'";
if (!index.includes(scripts) || !index.includes(csp)) {
    throw new Error('CalendarBar Windows index.html changed. Update the prototype frontend staging.');
}

const previewIndex = index
    .replace('<title>CalendarBar</title>', '<title>CalendarBar · Демо</title>')
    .replace(csp, "connect-src 'self' ipc: http://ipc.localhost")
    .replace(scripts, [
        '    <link rel="stylesheet" href="preview.css">',
        '    <script src="version.js" defer></script>',
        '    <script src="fixture.js" defer></script>',
        '    <script src="bridge.js" defer></script>',
        scripts
    ].join('\n'));

fs.mkdirSync(output, { recursive: true });
fs.writeFileSync(path.join(output, 'version.js'), 'const previewVersion = ' + JSON.stringify(version) + ';\n');
for (const file of ['styles.css', 'ui.js']) fs.copyFileSync(path.join(upstream, file), path.join(output, file));
for (const file of ['fixture.js', 'bridge.js', 'preview.css']) fs.copyFileSync(path.join(source, file), path.join(output, file));
fs.writeFileSync(path.join(output, 'index.html'), previewIndex);
