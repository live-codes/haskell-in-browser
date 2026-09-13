'use strict';

/**
 * Zero-dependency static file server for the spike.
 * Needed because Worker / fetch / WebAssembly streaming do not work over file://.
 *
 *   node serve.js [port] [root]
 *
 * `root` defaults to `public/` (the harness) and is resolved against this file, so
 * `node serve.js 8124 .` serves the whole repository — which is what the npm package
 * lives in.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, process.argv[3] || 'public');
const PORT = Number(process.argv[2] || 8123);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/markdown; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
};

const server = http.createServer((req, res) => {
  const urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
  let rel = urlPath === '/' ? '/index.html' : urlPath;

  const filePath = path.join(ROOT, rel);
  if (path.relative(ROOT, filePath).startsWith('..')) {
    res.writeHead(403).end('Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found: ' + rel);
      return;
    }
    const type = MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
    res.writeHead(200, {
      'Content-Type': type,
      // Not required for same-origin wasm, but harmless and helps caching behaviour.
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
});

server.listen(PORT, () => {
  console.log(`spike server: http://localhost:${PORT}/`);
  console.log('press Ctrl+C to stop');
});
