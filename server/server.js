'use strict';

const express = require('express');

/**
 * Creates the mock API. Data lives in memory and disappears on restart.
 *
 * Endpoints
 *   GET    /health
 *   POST   /locations/batch   { locations: [{id, latitude, longitude, accuracy, recordedAt}] }
 *   GET    /locations         everything stored so far
 *   DELETE /locations         wipe the store
 *   PUT    /admin/chaos       { failRate: 0..1, latencyMs: number, down: boolean }
 *
 * The upload endpoint is idempotent on `id`: re-sending a stored record is
 * reported under `duplicates` and never stored twice.
 */
function createApp({ failRate = Number(process.env.FAIL_RATE || 0) } = {}) {
  const app = express();
  app.use(express.json({ limit: '1mb' }));

  /** @type {Map<string, object>} */
  const store = new Map();
  const chaos = { failRate, latencyMs: 0, down: false };

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // Simulates a flaky network/server for the upload endpoint only.
  async function chaosMiddleware(req, res, next) {
    if (chaos.latencyMs > 0) await sleep(chaos.latencyMs);
    if (chaos.down || Math.random() < chaos.failRate) {
      return res.status(503).json({ error: 'Simulated outage' });
    }
    next();
  }

  function validate(item) {
    if (!item || typeof item !== 'object') return 'not an object';
    if (typeof item.id !== 'string' || item.id.length === 0) return 'id is required';
    if (typeof item.latitude !== 'number' || item.latitude < -90 || item.latitude > 90) {
      return 'latitude must be a number between -90 and 90';
    }
    if (typeof item.longitude !== 'number' || item.longitude < -180 || item.longitude > 180) {
      return 'longitude must be a number between -180 and 180';
    }
    if (typeof item.recordedAt !== 'string' || Number.isNaN(Date.parse(item.recordedAt))) {
      return 'recordedAt must be an ISO-8601 date';
    }
    return null;
  }

  app.get('/health', (_req, res) => res.json({ status: 'ok', stored: store.size }));

  app.post('/locations/batch', chaosMiddleware, (req, res) => {
    const items = req.body && req.body.locations;
    if (!Array.isArray(items)) {
      return res.status(400).json({ error: '`locations` must be an array' });
    }

    const accepted = [];
    const duplicates = [];
    const rejected = [];
    for (const item of items) {
      const problem = validate(item);
      if (problem) {
        rejected.push({ id: item && item.id ? String(item.id) : 'unknown', reason: problem });
      } else if (store.has(item.id)) {
        duplicates.push(item.id);
      } else {
        store.set(item.id, { ...item, receivedAt: new Date().toISOString() });
        accepted.push(item.id);
      }
    }
    console.log(
      `batch: ${accepted.length} accepted, ${duplicates.length} duplicate, ${rejected.length} rejected`,
    );
    res.json({ accepted, duplicates, rejected });
  });

  app.get('/locations', (_req, res) => {
    res.json({ count: store.size, locations: [...store.values()] });
  });

  app.delete('/locations', (_req, res) => {
    store.clear();
    res.status(204).end();
  });

  app.put('/admin/chaos', (req, res) => {
    const { failRate: f, latencyMs, down } = req.body || {};
    if (typeof f === 'number') chaos.failRate = Math.min(1, Math.max(0, f));
    if (typeof latencyMs === 'number') chaos.latencyMs = Math.max(0, latencyMs);
    if (typeof down === 'boolean') chaos.down = down;
    res.json(chaos);
  });

  return app;
}

if (require.main === module) {
  const port = Number(process.env.PORT || 3000);
  createApp().listen(port, '0.0.0.0', () => {
    console.log(`Mock API listening on http://0.0.0.0:${port}`);
  });
}

module.exports = { createApp };
