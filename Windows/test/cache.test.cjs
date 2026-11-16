'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { newProfile, withoutCalendarCache, calendarCacheBytes, saveDisk, loadDisk } = require('../src/store.cjs');

test('calendar cache size counts UTF-8 data and cleanup preserves the other account and personal settings', t => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'calendarbar-cache-'));
  t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
  const filename = path.join(folder, 'calendarbar.json');
  const event = { id: 'meeting', title: 'Командная встреча' };
  const account = {
    ...newProfile('work@example.test'),
    cache: { main: { meetings: { meeting: event }, coverage: [{ from: 1, to: 2 }], resources: {} } },
    background: [event], seenSeries: { meeting: 10 }, initialized: true, lastSync: 10,
    calendars: [{ id: 'main', visible: true }], password: 'encrypted fixture',
    activity: [{ meeting: event }], reminders: { meeting: { muted: true } },
    snoozes: [{ meeting: event, at: 99 }], colors: { meeting: 'red' }, pins: [{ title: 'Комната' }]
  };
  const other = { ...newProfile('inactive@example.test'), active: false, cache: { main: { meetings: { meeting: event } } } };
  saveDisk(filename, { accounts: [account, other], globals: { appearance: 'dark' } });
  const original = loadDisk(filename);
  const cleared = withoutCalendarCache(original.accounts[0], 20);
  saveDisk(filename, { ...original, accounts: [cleared, original.accounts[1]] });
  const saved = loadDisk(filename);
  const bytes = value => Buffer.byteLength(JSON.stringify(value));
  assert.equal(calendarCacheBytes(account),
    bytes(account.cache) + bytes(account.background) + bytes(account.seenSeries) - 6);
  assert.equal(calendarCacheBytes(saved.accounts[0]), 0);
  assert.deepEqual(saved.accounts[0].cache, {});
  assert.deepEqual(saved.accounts[0].background, []);
  assert.equal(saved.accounts[0].lastAttempt, 20);
  assert.equal(saved.accounts[0].initialized, false);
  for (const key of ['password', 'calendars', 'activity', 'reminders', 'snoozes', 'colors', 'pins', 'settings']) {
    assert.deepEqual(saved.accounts[0][key], account[key], key);
  }
  assert.deepEqual(saved.accounts[1], other);
  assert.deepEqual(saved.globals, original.globals);
});
