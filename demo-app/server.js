/**
 * demo-app/server.js
 * Minimal Express server. The platform is the product — this is just a target.
 */

const express = require('express');
const app = express();

const ENV_ID   = process.env.ENV_ID   || 'local';
const ENV_NAME = process.env.ENV_NAME || 'local';
const PORT     = parseInt(process.env.PORT || '3000', 10);

const startTime = Date.now();

app.get('/', (req, res) => {
  res.json({
    message: `Hello from sandbox environment: ${ENV_NAME}`,
    env_id:  ENV_ID,
    uptime:  Math.floor((Date.now() - startTime) / 1000),
  });
});

app.get('/health', (req, res) => {
  res.json({
    status:  'ok',
    env_id:  ENV_ID,
    uptime:  Math.floor((Date.now() - startTime) / 1000),
    time:    new Date().toISOString(),
  });
});

app.get('/info', (req, res) => {
  res.json({
    env_id:       ENV_ID,
    env_name:     ENV_NAME,
    node_version: process.version,
    uptime_s:     Math.floor((Date.now() - startTime) / 1000),
    memory_mb:    Math.round(process.memoryUsage().rss / 1024 / 1024),
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[${new Date().toISOString()}] Demo app started — env=${ENV_NAME} id=${ENV_ID} port=${PORT}`);
});
