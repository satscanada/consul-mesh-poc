require('dotenv').config();
const express = require('express');
const { initSchema } = require('./db/cockroach');
const itemsRouter = require('./routes/items');

const app = express();
const PORT = process.env.PORT || 3000;
const APP_VERSION = process.env.APP_VERSION || 'v1';

app.use(express.json());

// Stamp every response with the running version so the UI can display a badge
app.use((_req, res, next) => { res.set('X-Api-Version', APP_VERSION); next(); });

app.get('/health', (_req, res) => res.json({ status: 'ok', version: APP_VERSION }));
app.use('/api/items', itemsRouter);

initSchema()
  .then(() => app.listen(PORT, () => console.log(`api-server listening on port ${PORT}`)))
  .catch(err => { console.error('Schema init failed:', err.message); process.exit(1); });
