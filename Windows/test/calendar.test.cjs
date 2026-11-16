'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { parseCalendar, conferenceURL, telemostDesktopURL, browserURL, yandexCreateURL, yandexEditURL } = require('../src/calendar.cjs');

function parse(events, options = {}) {
  return parseCalendar(`BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${events}\r\nEND:VCALENDAR`, {
    calendarID: 'work',
    calendarName: 'Рабочий',
    defaultTimeZone: 'UTC',
    from: Date.parse('2026-10-01T00:00:00Z'),
    to: Date.parse('2026-12-01T00:00:00Z'),
    ...options,
  });
}

function event(properties) {
  return `BEGIN:VEVENT\nUID:series\n${properties}\nEND:VEVENT`;
}

const starts = meetings => meetings.map(meeting => new Date(meeting.start).toISOString().slice(0, 16));

test('monthly weekdays and set positions use complete months before filtering and COUNT', () => {
  const input = event('DTSTART:20260930T100000Z\nRRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=2');
  assert.deepEqual(starts(parse(input)), ['2026-10-30T10:00']);
  assert.deepEqual(parse(input, { to: Date.parse('2026-10-15T00:00:00Z') }), []);
  const ordinal = event('DTSTART:20260925T100000Z\nRRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3');
  assert.deepEqual(starts(parse(ordinal)), ['2026-10-30T10:00', '2026-11-27T10:00']);
});

test('weekly rules keep their original interval and daily positions are selected before COUNT', () => {
  const weekly = event('DTSTART:20261019T100000Z\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=MO;COUNT=4');
  assert.deepEqual(starts(parse(weekly)), ['2026-10-19T10:00', '2026-10-21T10:00', '2026-11-02T10:00', '2026-11-04T10:00']);
  const daily = event('DTSTART:20261021T170000Z\nRRULE:FREQ=DAILY;COUNT=3;BYHOUR=9,17;BYSETPOS=-1');
  assert.deepEqual(starts(parse(daily)), ['2026-10-21T17:00', '2026-10-22T17:00', '2026-10-23T17:00']);
});

test('yearly leap dates and hourly and minutely interval rules expand without clamping', () => {
  const yearly = event('DTSTART:20240229T100000Z\nRRULE:FREQ=YEARLY;COUNT=3');
  assert.deepEqual(starts(parse(yearly, {
    from: Date.parse('2025-01-01T00:00:00Z'), to: Date.parse('2033-01-01T00:00:00Z'),
  })), ['2028-02-29T10:00', '2032-02-29T10:00']);
  const hourly = event('DTSTART:20261021T100500Z\nRRULE:FREQ=HOURLY;INTERVAL=2;COUNT=4;BYMINUTE=5,25');
  assert.deepEqual(starts(parse(hourly)), ['2026-10-21T10:05', '2026-10-21T10:25', '2026-10-21T12:05', '2026-10-21T12:25']);
  const minutely = event('DTSTART:20261021T105500Z\nRRULE:FREQ=MINUTELY;INTERVAL=11;COUNT=3');
  assert.deepEqual(starts(parse(minutely)), ['2026-10-21T10:55', '2026-10-21T11:06', '2026-10-21T11:17']);
  const repeatedHour = event('DTSTART;TZID=Europe/Paris:20261025T011500\nRRULE:FREQ=HOURLY;COUNT=4');
  assert.deepEqual(starts(parse(repeatedHour)), ['2026-10-24T23:15', '2026-10-25T00:15', '2026-10-25T01:15', '2026-10-25T02:15']);
});

test('exception lists and overrides preserve scope, original dates, and explicit cancellation', () => {
  const meetings = parse([
    event('DTSTART:20261021T100000Z\nDURATION:PT30M\nRRULE:FREQ=DAILY;COUNT=4\nEXDATE:20261022T100000Z\nRDATE:20261025T100000Z\nDESCRIPTION:План'),
    event('RECURRENCE-ID;RANGE=THISANDFUTURE:20261023T100000Z\nDTSTART:20261023T110000Z\nSUMMARY:Перенос'),
    event('RECURRENCE-ID:20261024T100000Z\nSTATUS:CANCELLED'),
  ].join('\n'), { accountLogin: 'one@example.test' });
  assert.deepEqual(starts(meetings), ['2026-10-21T10:00', '2026-10-23T11:00', '2026-10-24T10:00', '2026-10-25T11:00']);
  assert.equal(meetings[1].originalStart, Date.parse('2026-10-23T10:00:00Z'));
  assert.equal(meetings[1].details, 'План');
  assert.equal(meetings[1].end - meetings[1].start, 30 * 60 * 1_000);
  assert.equal(meetings[2].cancelled, true);
  assert.equal(new Set(meetings.map(meeting => meeting.id)).size, 4);
  assert.match(meetings[0].calendarID, /^account:.*:work$/);
});

test('time zones preserve recurrence wall time and all-day civil dates', () => {
  const timed = parse(event('DTSTART;TZID=Europe/Paris:20261024T090000\nRRULE:FREQ=DAILY;COUNT=3'));
  assert.deepEqual(starts(timed), ['2026-10-24T07:00', '2026-10-25T08:00', '2026-10-26T08:00']);
  const allDay = event('DTSTART;VALUE=DATE:20261024\nRRULE:FREQ=DAILY;COUNT=3');
  const physical = parse(allDay, { defaultTimeZone: 'Europe/Paris' });
  assert.equal(physical[1].end - physical[1].start, 25 * 3_600_000);
  const visible = parse(allDay, {
    defaultTimeZone: 'Europe/Paris', displayZone: 'America/Los_Angeles',
    from: Date.parse('2026-10-25T07:00:00Z'), to: Date.parse('2026-10-26T07:00:00Z'),
  });
  assert.deepEqual(starts(visible), ['2026-10-25T07:00']);
  assert.deepEqual(visible[0].allDayDates, { start: '2026-10-25', end: '2026-10-26' });
});

test('nominal durations and following overrides match calendar day arithmetic across daylight saving', () => {
  const events = [
    event('DTSTART;TZID=Europe/Paris:20260328T023000\nRRULE:FREQ=DAILY;COUNT=3\nDURATION:P1D'),
    event('RECURRENCE-ID;TZID=Europe/Paris;RANGE=THISANDFUTURE:20260328T023000\nDTSTART;TZID=Europe/Paris:20260329T033000'),
  ].join('\n');
  const meetings = parse(events, { from: Date.parse('2026-03-28T00:00:00Z'), to: Date.parse('2026-04-03T00:00:00Z') });
  assert.deepEqual(starts(meetings), ['2026-03-29T01:30', '2026-03-31T00:30', '2026-04-01T00:30']);
  const [unshifted] = parse(event('DTSTART;TZID=Europe/Paris:20260328T023000\nDURATION:P1D'), {
    from: Date.parse('2026-03-28T00:00:00Z'), to: Date.parse('2026-03-31T00:00:00Z'),
  });
  assert.equal(new Date(unshifted.end).toISOString(), '2026-03-29T01:30:00.000Z');
});

test('event URL, attendee response, folded notes, and join URL remain separate', () => {
  const sourceURL = 'https://calendar.yandex.ru/event?event_id=123';
  const [meeting] = parse(event([
    'DTSTART:20261021T100000Z',
    'ATTENDEE;CN="Иван: менеджер";PARTSTAT=ACCEPTED:mailto:test@example.test',
    'DESCRIPTION:План\\nhttps://telemost.yandex.ru/j/123',
    ' 456',
    `URL:${sourceURL}`,
    'BEGIN:VALARM',
    'DESCRIPTION:Не описание встречи',
    'END:VALARM',
  ].join('\n')));
  assert.equal(meeting.sourceURL, sourceURL);
  assert.equal(meeting.link, 'https://telemost.yandex.ru/j/123456');
  assert.equal(meeting.attendees[0].name, 'Иван: менеджер');
  assert.equal(meeting.attendees[0].response, 'ACCEPTED');
  assert.equal(conferenceURL([sourceURL], ['https://example.test/specification']), null);
  assert.equal(telemostDesktopURL(meeting.link), 'telemost://https://telemost.yandex.ru/j/123456');
  assert.equal(telemostDesktopURL('https://telemost.yandex.ru:443/j/123456'), null);
  assert.equal(telemostDesktopURL('https://@telemost.yandex.ru/j/123456'), null);
  assert.equal(new URL(browserURL(`${meeting.link}?skip_app=0&other=1`)).searchParams.get('skip_app'), '1');
  assert.equal(yandexEditURL(meeting), sourceURL);
  const create = new URL(yandexCreateURL(Date.parse('2026-10-22T23:30:00Z'), { timeZone: 'Europe/Moscow' }));
  assert.equal(create.searchParams.get('start'), '2026-10-23T02:30:00');
  assert.equal(create.searchParams.get('end'), '2026-10-23T03:00:00');
});

test('bad or unsupported data is rejected rather than displaying altered recurrence data', () => {
  assert.throws(() => parse(event('DTSTART:20260230T100000Z')), /начало встречи/);
  assert.throws(() => parse(event('DTSTART;TZID=Not\/Known:20261021T100000')), /часовой пояс/);
  assert.throws(() => parse(event('DTSTART:20261021T100000Z\nRRULE:FREQ=DAILY;X-UNKNOWN=1')), /X-UNKNOWN/);
});
