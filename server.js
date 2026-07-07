#!/usr/bin/env node
/*
 * PCStress — server web alternativo (Node.js, zero dipendenze).
 * Per chi ha Node installato o vuole servire l'app da Linux/Mac.
 * Uso:  node server.js [porta]      (porta predefinita: 8080)
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORTA = parseInt(process.argv[2], 10) || 8080;
const RADICE = __dirname;

const TIPI_MIME = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8',
  '.ps1': 'application/octet-stream',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

const server = http.createServer((req, res) => {
  let percorso;
  try {
    percorso = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  } catch (e) {
    res.writeHead(400); res.end('400'); return;
  }
  if (percorso.endsWith('/')) percorso += 'index.html';
  const completo = path.normalize(path.join(RADICE, percorso));
  if (completo !== RADICE && !completo.startsWith(RADICE + path.sep)) {
    res.writeHead(403); res.end('403 - accesso negato'); return;
  }
  fs.stat(completo, (err, st) => {
    let file = completo;
    if (!err && st.isDirectory()) file = path.join(completo, 'index.html');
    fs.readFile(file, (err2, dati) => {
      if (err2) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('404 - risorsa non trovata');
        return;
      }
      const tipo = TIPI_MIME[path.extname(file).toLowerCase()] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': tipo, 'Content-Length': dati.length });
      res.end(dati);
    });
  });
});

server.listen(PORTA, '0.0.0.0', () => {
  console.log('');
  console.log('=============================================');
  console.log('  PCStress — server web attivo (Node.js)');
  console.log('=============================================');
  console.log('  Apri il test da questo PC:');
  console.log(`      http://localhost:${PORTA}/`);
  console.log('');
  console.log('  Apri il test dagli ALTRI PC della rete:');
  const interfacce = os.networkInterfaces();
  for (const nome of Object.keys(interfacce)) {
    for (const ind of interfacce[nome] || []) {
      if (ind.family === 'IPv4' && !ind.internal && !ind.address.startsWith('169.254.')) {
        console.log(`      http://${ind.address}:${PORTA}/`);
      }
    }
  }
  console.log('');
  console.log('  Premi CTRL+C per fermare il server.');
  console.log('');
});
