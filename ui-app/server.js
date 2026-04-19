require('dotenv').config();
const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 4000;
// api-server is reached through the Consul Connect sidecar on localhost
const API_URL = process.env.API_URL || 'http://api-server:3000';

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

// Serve SPA for all other routes
app.get('*', (_req, res) => {
  res.sendFile(path.join(__dirname, 'src', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`ui-app listening on port ${PORT}`);
});
