require('dotenv').config();
const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 4000;
// api-server is reached through the Consul Connect sidecar on localhost
const API_URL = process.env.API_URL || 'http://api-server:3000';

// ── In-memory traffic counters (resets on pod restart — demo only) ──────────
const MAX_TIMELINE = 50;
const trafficStats = { v1: 0, v2: 0, total: 0, timeline: [] };

app.use(express.static(path.join(__dirname, 'src')));
app.use(express.json());

function buildUpstreamHeaders(req) {
  const headers = {};

  for (const [key, value] of Object.entries(req.headers)) {
    if (value === undefined) continue;
    if (['host', 'content-length', 'connection'].includes(key)) continue;
    headers[key] = value;
  }

  return headers;
}

// Proxy: forward all /api/* calls to the api-server through the mesh
app.all('/api/*', async (req, res) => {
  const { default: fetch } = await import('node-fetch');
  const target = `${API_URL}${req.path}`;
  try {
    const apiRes = await fetch(target, {
      method: req.method,
      headers: buildUpstreamHeaders(req),
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : JSON.stringify(req.body),
    });

    res.status(apiRes.status);

    const contentType = apiRes.headers.get('content-type');
    if (contentType) {
      res.set('content-type', contentType);
    }

    // Forward the version header so the browser UI can show the version badge
    const apiVersion = apiRes.headers.get('x-api-version');
    if (apiVersion) res.set('x-api-version', apiVersion);
    const apiVariant = apiRes.headers.get('x-api-variant');
    if (apiVariant) res.set('x-api-variant', apiVariant);

    // Track per-version hit counts for the live traffic dashboard
    if (apiVersion) {
      const v = apiVersion.toLowerCase();
      if (v === 'v1' || v === 'v2') trafficStats[v]++;
      trafficStats.total++;
      trafficStats.timeline.push({ ts: Date.now(), version: v });
      if (trafficStats.timeline.length > MAX_TIMELINE) trafficStats.timeline.shift();
    }

    const bodyText = await apiRes.text();
    if (!bodyText) {
      return res.end();
    }

    if (contentType && contentType.includes('application/json')) {
      return res.send(bodyText);
    }

    return res.send(bodyText);
  } catch (err) {
    res.status(502).json({ error: 'api-server unreachable', detail: err.message });
  }
});

// ── Internal stats endpoints (traffic visualization dashboard) ──────────────

// GET /internal/stats — current counters snapshot
app.get('/internal/stats', (_req, res) => res.json(trafficStats));

// GET /internal/stats/stream — SSE stream, pushes updated counters every 1 s
app.get('/internal/stats/stream', (req, res) => {
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no', // disable nginx buffering if present
  });
  res.flushHeaders();
  const timer = setInterval(() => {
    res.write(`data: ${JSON.stringify(trafficStats)}\n\n`);
  }, 1000);
  res.on('close', () => clearInterval(timer));
});

// DELETE /internal/stats — reset all counters (called by the Reset button)
app.delete('/internal/stats', (_req, res) => {
  trafficStats.v1 = 0;
  trafficStats.v2 = 0;
  trafficStats.total = 0;
  trafficStats.timeline = [];
  res.json({ reset: true });
});

app.get('/canary', (_req, res) => {
  res.sendFile(path.join(__dirname, 'src', 'canary.html'));
});

app.get('/internal/canary-config', async (_req, res) => {
  const { default: fetch } = await import('node-fetch');

  function collectRoutes(node, acc = []) {
    if (!node || typeof node !== 'object') return acc;
    if (Array.isArray(node)) {
      for (const item of node) collectRoutes(item, acc);
      return acc;
    }
    if (Array.isArray(node.routes)) {
      acc.push(...node.routes);
    }
    for (const value of Object.values(node)) {
      collectRoutes(value, acc);
    }
    return acc;
  }

  function normalizeClusterName(name) {
    return String(name || '').toLowerCase();
  }

  try {
    const response = await fetch('http://127.0.0.1:19000/config_dump');
    if (!response.ok) {
      return res.status(response.status).json({
        error: 'Unable to read Envoy config dump',
        detail: await response.text(),
      });
    }

    const payload = await response.json();
    const routes = collectRoutes(payload);
    const weightedRoute = routes.find((route) => {
      const prefix = route?.match?.prefix || route?.match?.pathSeparatedPrefix || '';
      const clusters = route?.route?.weighted_clusters?.clusters;
      if (!Array.isArray(clusters) || !String(prefix).startsWith('/api')) return false;
      return clusters.some((cluster) => {
        const name = normalizeClusterName(cluster?.name);
        return name.includes('api-server') && (name.includes('v1') || name.includes('v2'));
      });
    });

    const clusters = weightedRoute?.route?.weighted_clusters?.clusters;
    if (!Array.isArray(clusters) || !clusters.length) {
      return res.status(404).json({
        error: 'Configured canary split not found in Envoy route config',
        detail: 'No weighted api-server route is currently active in the sidecar config dump.',
      });
    }

    const rawSplits = clusters
      .map((cluster) => {
        const name = normalizeClusterName(cluster?.name);
        const subset = name.includes('v2') ? 'v2' : name.includes('v1') ? 'v1' : 'default';
        return {
          subset,
          weight: Number(cluster?.weight?.value ?? cluster?.weight ?? 0),
        };
      })
      .filter((split) => split.subset === 'v1' || split.subset === 'v2');

    const totalWeight = rawSplits.reduce((sum, split) => sum + split.weight, 0);
    const splits = totalWeight > 0
      ? rawSplits.map((split) => ({
          subset: split.subset,
          weight: Math.round((split.weight / totalWeight) * 100),
        }))
      : rawSplits;

    return res.json({ splits });
  } catch (err) {
    return res.status(502).json({ error: 'canary config unavailable', detail: err.message });
  }
});

// Serve SPA for all other routes
app.get('*', (_req, res) => {
  res.sendFile(path.join(__dirname, 'src', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`ui-app listening on port ${PORT}`);
});
