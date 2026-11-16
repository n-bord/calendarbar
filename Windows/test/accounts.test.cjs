'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { YandexCalendarClient, mergeCalendarMeetings } = require('../src/accounts.cjs');

const login = 'me@example.org';
const calendar = {
  id: 'https://caldav.yandex.ru/accounts/me/work/',
  name: 'Рабочий',
  accountLogin: login
};
const start = Date.parse('2026-10-22T00:00:00Z');
const end = Date.parse('2026-10-24T00:00:00Z');
const displayZone = 'Europe/Moscow';

function events(uid, summary = 'Встреча') {
  return [
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'BEGIN:VEVENT',
    `UID:${uid}`, `SUMMARY:${summary}`, 'DTSTART:20261023T100000Z', 'DTEND:20261023T110000Z',
    'END:VEVENT', 'END:VCALENDAR'
  ].join('\r\n');
}

function multistatus(content = '') {
  return new Response(`<multistatus xmlns="DAV:" xmlns:x="urn:ietf:params:xml:ns:caldav">${content}</multistatus>`,
    { status: 207 });
}

function entry(href, properties) {
  return `<response><href>${href}</href><propstat><prop>${properties}</prop><status>HTTP/1.1 200 OK</status></propstat></response>`;
}

function eventEntry(uid, etag, data) {
  const event = data === undefined ? '' : `<x:calendar-data><![CDATA[${data}]]></x:calendar-data>`;
  return entry(calendar.id + uid + '.ics', `<getetag>${etag}</getetag>${event}`);
}

test('discovers and scopes a Yandex calendar and refuses to follow a redirect', async () => {
  const replies = [
    [ '/', multistatus(entry('/', '<current-user-principal><href>/accounts/me/</href></current-user-principal>')) ],
    [ '/accounts/me/', multistatus(entry('/accounts/me/', '<x:calendar-home-set><href>/accounts/me/calendars/</href></x:calendar-home-set>')) ],
    [ '/accounts/me/calendars/', multistatus(entry(calendar.id,
      '<resourcetype><x:calendar/></resourcetype><displayname>Дела &amp; встречи</displayname>')) ]
  ];
  const client = new YandexCalendarClient(login, 'test-only', {
    async fetch(url, request) {
      const [path, response] = replies.shift();
      assert.equal(url.pathname, path);
      assert.equal(request.method, 'PROPFIND');
      assert.equal(request.redirect, 'manual');
      assert.equal(request.headers.Authorization, 'Basic ' + Buffer.from(login + ':test-only').toString('base64'));
      return response;
    }
  });
  const [work] = await client.calendars();
  assert.deepEqual(work, {
    id: `account:${Buffer.from(login).toString('base64')}:${calendar.id}`,
    sourceID: calendar.id,
    accountLogin: login,
    name: 'Дела & встречи'
  });
  assert.equal(replies.length, 0);

  const redirected = new YandexCalendarClient(login, 'test-only', {
    async fetch(url, { redirect }) {
      assert.equal(url.hostname, 'caldav.yandex.ru');
      assert.equal(redirect, 'manual');
      return new Response(null, { status: 302, headers: { Location: 'https://example.org/' } });
    }
  });
  await assert.rejects(() => redirected.calendars(), /HTTP 302/);
});

test('reuses unchanged bodies and preserves only failed resources on partial refresh', async () => {
  const unchanged = calendar.id + 'same.ics';
  const changed = calendar.id + 'changed.ics';
  const vanished = calendar.id + 'vanished.ics';
  const cached = {
    [unchanged]: { href: unchanged, etag: '"1"', data: events('same') },
    [changed]: { href: changed, etag: '"1"', data: events('changed') },
    [vanished]: { href: vanished, etag: '"1"', data: events('vanished') }
  };
  let count = 0;
  const client = new YandexCalendarClient(login, 'test-only', {
    async fetch(url, { method, body }) {
      assert.equal(url.href, calendar.id);
      assert.equal(method, 'REPORT');
      count++;
      if (body.includes('calendar-query')) return multistatus(eventEntry('same', '"1"') + eventEntry('changed', '"2"'));
      assert.match(body, /<d:href>\/accounts\/me\/work\/changed\.ics<\/d:href>/);
      assert.doesNotMatch(body, /same\.ics/);
      return multistatus(eventEntry('changed', '"2"', 'malformed iCalendar'));
    }
  });
  const result = await client.meetings(calendar, start, end, { cached, displayZone });
  assert.equal(count, 2);
  assert.equal(result.complete, false);
  assert.deepEqual(Object.keys(result.resources), [unchanged]);
  assert.deepEqual(Object.keys(result.failedResources), [changed]);
  assert.deepEqual(result.meetings.map(meeting => meeting.resourceURL), [unchanged]);
  const merged = mergeCalendarMeetings([
    { id: 'old', resourceURL: changed }, { id: 'gone', resourceURL: vanished }
  ], result);
  assert.deepEqual(merged.map(meeting => meeting.resourceURL), [unchanged, changed]);
  assert.equal(cached[changed].etag, '"1"');
});

test('re-lists once when a resource is deleted during download', async () => {
  const methods = [];
  const client = new YandexCalendarClient(login, 'test-only', {
    async fetch(_url, { method, body }) {
      methods.push(method);
      if (method === 'GET') return new Response(null, { status: 404 });
      if (body.includes('calendar-multiget')) return multistatus(
        `<response><href>${calendar.id}a.ics</href><status>HTTP/1.1 404</status></response>`
      );
      return methods.length === 1 ? multistatus(eventEntry('a', '"1"')) : multistatus();
    }
  });
  const result = await client.meetings(calendar, start, end, { displayZone });
  assert.deepEqual(methods, ['REPORT', 'REPORT', 'GET', 'REPORT']);
  assert.deepEqual(result.meetings, []);
  assert.equal(result.complete, true);
});

test('queries complete iCalendar bodies when metadata-only REPORT is unavailable', async () => {
  const client = new YandexCalendarClient(login, 'test-only', {
    async fetch(_url, { body }) {
      return body.includes('calendar-data')
        ? multistatus(eventEntry('a', '"1"', events('a')))
        : new Response(null, { status: 405 });
    }
  });
  const result = await client.meetings(calendar, start, end, { displayZone });
  assert.equal(result.complete, true);
  assert.equal(result.meetings.length, 1);
});

test('rejects a foreign discovery URL before sending credentials to it', async () => {
  let requests = 0;
  const client = new YandexCalendarClient(login, 'test-only', {
    async fetch(url) {
      requests++;
      assert.equal(url.hostname, 'caldav.yandex.ru');
      return multistatus(entry('/', '<current-user-principal><href>https://example.org/principal/</href></current-user-principal>'));
    }
  });
  await assert.rejects(() => client.calendars(), /вне доверенного сервера/);
  assert.equal(requests, 1);
});
