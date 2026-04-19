const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.DB_HOST || 'cockroachdb',
  port: parseInt(process.env.DB_PORT || '26257', 10),
  database: process.env.DB_NAME || 'defaultdb',
  user: process.env.DB_USER || 'root',
  password: process.env.DB_PASSWORD || '',
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
});

module.exports = { pool };
