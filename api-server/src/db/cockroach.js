const { Pool } = require('pg');
const fs = require('fs');

function buildSslConfig() {
  if (process.env.DB_SSL !== 'true') return false;
  const certPath = process.env.DB_SSL_ROOT_CERT || '/etc/ssl/cockroachdb/root.crt';
  return {
    rejectUnauthorized: true,
    ca: fs.readFileSync(certPath).toString(),
  };
}

const pool = new Pool({
  host: process.env.DB_HOST || 'cockroachdb',
  port: parseInt(process.env.DB_PORT || '26257', 10),
  database: process.env.DB_NAME || 'defaultdb',
  user: process.env.DB_USER || 'root',
  password: process.env.DB_PASSWORD || '',
  ssl: buildSslConfig(),
});

async function initSchema() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS items (
      id          INT PRIMARY KEY DEFAULT unique_rowid(),
      name        STRING NOT NULL,
      description STRING
    )
  `);
}

module.exports = { pool, initSchema };
