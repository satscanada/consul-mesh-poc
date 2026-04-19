require('dotenv').config();
const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 4000;
// api-server is reached through the Consul Connect sidecar on localhost
const API_URL = process.env.API_URL || 'http://api-server:3000'\;

app.use(express.static(path.join(__dirname, 'src')));
app.use(express.json());

// Proxy: forward all /api/* calls to the api-server through the mesh
app.all('/api/*', async (req, res) => {
  const { default: fetch } = await import('node-fetch');
  const target = `${API_URL}${req.path}`;
  try {
    const apiRes = await fetch(target, {
      method: req.method,
      headers: { 'Content-Type': 'application/json' },
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : JSON.stringify(req.body),
    });
    const data = await apiRes.json();
    res.status(apiRes.status).json(data);
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
