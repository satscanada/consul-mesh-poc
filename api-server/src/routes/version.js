const { Router } = require('express');

const router = Router();

router.get('/', (_req, res) => {
  res.json({
    version: process.env.APP_VERSION || 'v1',
    variant: process.env.APP_VARIANT || 'variant-a',
    timestamp: new Date().toISOString(),
  });
});

module.exports = router;
