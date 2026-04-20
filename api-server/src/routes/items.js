const { Router } = require('express');
const { pool } = require('../db/cockroach');

const router = Router();
const APP_VARIANT = process.env.APP_VARIANT || 'variant-a';

function parseItemPayload(body) {
  const { name, description } = body || {};

  if (typeof name !== 'string' || !name.trim()) {
    return { error: 'name is required' };
  }

  if (description !== undefined && description !== null && typeof description !== 'string') {
    return { error: 'description must be a string' };
  }

  return {
    value: {
      name: name.trim(),
      description: typeof description === 'string' ? description.trim() : null,
    },
  };
}

function decorateItem(item) {
  if (APP_VARIANT !== 'variant-b' || !item) {
    return item;
  }

  return {
    ...item,
    name: `Beta · ${item.name}`,
    description: item.description ? `${item.description} (beta preview)` : 'beta preview',
  };
}

// GET all items
router.get('/', async (_req, res) => {
  try {
    const { rows } = await pool.query('SELECT * FROM items ORDER BY id');
    res.json(rows.map(decorateItem));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET single item
router.get('/:id', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT * FROM items WHERE id = $1', [req.params.id]);
    if (!rows.length) return res.status(404).json({ error: 'Not found' });
    res.json(decorateItem(rows[0]));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// CREATE item
router.post('/', async (req, res) => {
  const payload = parseItemPayload(req.body);
  if (payload.error) return res.status(400).json({ error: payload.error });

  const { name, description } = payload.value;
  try {
    const { rows } = await pool.query(
      'INSERT INTO items (name, description) VALUES ($1, $2) RETURNING *',
      [name, description]
    );
    res.status(201).json(decorateItem(rows[0]));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// UPDATE item
router.put('/:id', async (req, res) => {
  const payload = parseItemPayload(req.body);
  if (payload.error) return res.status(400).json({ error: payload.error });

  const { name, description } = payload.value;
  try {
    const { rows } = await pool.query(
      'UPDATE items SET name = $1, description = $2 WHERE id = $3 RETURNING *',
      [name, description, req.params.id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Not found' });
    res.json(decorateItem(rows[0]));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// DELETE item
router.delete('/:id', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'DELETE FROM items WHERE id = $1 RETURNING *',
      [req.params.id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Not found' });
    res.json({ deleted: decorateItem(rows[0]) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;
