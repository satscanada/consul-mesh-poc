require('dotenv').config();
const express = require('express');
const { initSchema } = require('./db/cockroach');
const itemsRouter = require('./routes/items');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

app.get('/health', (_req, res) => res.json({ status: 'ok' }));
app.use('/api/items', itemsRouter);

initSchema()
  .then(() => app.listen(PORT, () => console.log(`api-server listening on port ${PORT}`)))
  .catch(err => { console.error('Schema init failed:', err.message); process.exit(1); });
