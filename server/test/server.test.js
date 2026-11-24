'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../server');

async function withServer(fn) {
  const server = createApp().listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    await fn(base);
  } finally {
    server.close();
  }
}

const loc = (id, extra = {}) => ({
  id,
  latitude: 12.9,
  longitude: 77.6,
  accuracy: 5,
  recordedAt: '2026-01-01T10:00:00.000Z',
  ...extra,
});

const post = (base, body) =>
  fetch(`${base}/locations/batch`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });

test('stores new locations and reports them as accepted', () =>
  withServer(async (base) => {
    const res = await post(base, { locations: [loc('a'), loc('b')] });
    assert.equal(res.status, 200);
    const json = await res.json();
    assert.deepEqual(json.accepted, ['a', 'b']);
    const all = await (await fetch(`${base}/locations`)).json();
    assert.equal(all.count, 2);
  }));

test('re-sending a stored id is a duplicate and is not stored twice', () =>
  withServer(async (base) => {
    await post(base, { locations: [loc('a')] });
    const json = await (await post(base, { locations: [loc('a')] })).json();
    assert.deepEqual(json.duplicates, ['a']);
    assert.deepEqual(json.accepted, []);
    const all = await (await fetch(`${base}/locations`)).json();
    assert.equal(all.count, 1);
  }));

test('invalid records are rejected individually', () =>
  withServer(async (base) => {
    const json = await (
      await post(base, { locations: [loc('ok'), loc('bad', { latitude: 123 })] })
    ).json();
    assert.deepEqual(json.accepted, ['ok']);
    assert.equal(json.rejected.length, 1);
    assert.equal(json.rejected[0].id, 'bad');
  }));

test('a malformed body gets a 400', () =>
  withServer(async (base) => {
    const res = await post(base, { nope: true });
    assert.equal(res.status, 400);
  }));

test('chaos mode makes uploads fail with 503 and nothing is stored', () =>
  withServer(async (base) => {
    await fetch(`${base}/admin/chaos`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ down: true }),
    });
    const res = await post(base, { locations: [loc('a')] });
    assert.equal(res.status, 503);
    const all = await (await fetch(`${base}/locations`)).json();
    assert.equal(all.count, 0);
  }));
