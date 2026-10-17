import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';

export function createRelay({ maxRooms = 1000, maxTunnels = 2000, tls } = {}) {
  const rooms = new Map();
  const pending = new Map();
  const sockets = new Set();
  const connections = new Set();
  const upgrades = new Map();
  const server = (tls ? https : http).createServer(tls ?? {}, (req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"ok":true}');
    } else { res.writeHead(404); res.end(); }
  });
  const wsServer = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024, perMessageDeflate: false });
  server.requestTimeout = 10000;
  server.headersTimeout = 10000;
  server.maxHeadersCount = 30;
  server.on('connection', socket => {
    connections.add(socket);
    if (connections.size > maxTunnels * 3 + maxRooms) socket.destroy();
    socket.on('close', () => connections.delete(socket));
  });
  function track(ws) {
    sockets.add(ws);
    ws.alive = true;
    ws.on('pong', () => { ws.alive = true; });
    ws.on('error', () => ws.terminate());
    ws.on('close', () => sockets.delete(ws));
  }
  function reject(socket, code) {
    socket.end(`HTTP/1.1 ${code} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  }
  function bridge(first, second) {
    const close = () => { first.terminate(); second.terminate(); };
    for (const [source, target] of [[first, second], [second, first]]) {
      source.on('message', (bytes, binary) => {
        if (!binary || target.readyState !== WebSocket.OPEN) { close(); return; }
        source.pause();
        target.send(bytes, { binary: true }, error => {
          if (error) close(); else source.resume();
        });
      });
      source.on('close', close);
      source.on('error', close);
    }
    first.resume();
  }
  server.on('upgrade', (req, socket, head) => {
    let url;
    try { url = new URL(req.url, 'http://relay'); } catch { reject(socket, 400); return; }
    const room = url.searchParams.get('room') ?? '';
    if (!/^[A-Za-z0-9_-]{43}$/.test(room) || sockets.size >= maxTunnels * 2 + maxRooms) {
      reject(socket, 400); return;
    }
    const address = socket.remoteAddress ?? '';
    const recent = upgrades.get(address);
    const now = Date.now();
    if (recent && now - recent.start < 60000 && recent.count >= 600) { reject(socket, 429); return; }
    upgrades.set(address, recent && now - recent.start < 60000 ? { ...recent, count: recent.count + 1 } : { start: now, count: 1 });
    if (url.pathname === '/host') {
      if (rooms.has(room) || rooms.size >= maxRooms) { reject(socket, 409); return; }
      wsServer.handleUpgrade(req, socket, head, ws => {
        if (rooms.has(room)) { ws.close(1008); return; }
        track(ws);
        rooms.set(room, ws);
        ws.on('message', () => ws.close(1008));
        ws.on('close', () => { if (rooms.get(room) === ws) rooms.delete(room); });
      });
    } else if (url.pathname === '/join') {
      const host = rooms.get(room);
      if (!host || host.readyState !== WebSocket.OPEN) { reject(socket, 503); return; }
      if ([...pending.values()].filter(p => p.room === room).length >= 16) { reject(socket, 429); return; }
      wsServer.handleUpgrade(req, socket, head, ws => {
        track(ws);
        ws.pause();
        const id = crypto.randomBytes(24).toString('base64url');
        const timer = setTimeout(() => { pending.delete(id); ws.terminate(); }, 15000);
        timer.unref();
        pending.set(id, { room, ws, timer });
        ws.on('close', () => { clearTimeout(timer); pending.delete(id); });
        host.send(JSON.stringify({ type: 'open', id }));
      });
    } else if (url.pathname === '/accept') {
      const id = url.searchParams.get('id');
      const partner = pending.get(id);
      if (!partner || partner.room !== room) { reject(socket, 404); return; }
      pending.delete(id);
      clearTimeout(partner.timer);
      wsServer.handleUpgrade(req, socket, head, ws => { track(ws); bridge(partner.ws, ws); });
    } else reject(socket, 404);
  });
  const ping = setInterval(() => {
    for (const ws of sockets) {
      if (!ws.alive) { ws.terminate(); continue; }
      ws.alive = false;
      ws.ping();
    }
    for (const [address, value] of upgrades) if (Date.now() - value.start >= 60000) upgrades.delete(address);
  }, 20000);
  ping.unref();
  return {
    server,
    async listen(port = 8080, host = '127.0.0.1') {
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, host, resolve); });
      return server.address().port;
    },
    async close() {
      clearInterval(ping);
      for (const value of pending.values()) clearTimeout(value.timer);
      pending.clear();
      for (const ws of sockets) ws.terminate();
      for (const socket of connections) socket.destroy();
      await new Promise(resolve => server.close(resolve));
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const tls = process.env.TLS_CERT_FILE && process.env.TLS_KEY_FILE
    ? { cert: fs.readFileSync(process.env.TLS_CERT_FILE), key: fs.readFileSync(process.env.TLS_KEY_FILE) } : undefined;
  const relay = createRelay({ tls });
  const port = await relay.listen(Number(process.env.PORT ?? 8080), process.env.BIND_HOST ?? '127.0.0.1');
  process.stdout.write(`LinkInDrop relay listening on ${port}\n`);
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, async () => { await relay.close(); process.exit(0); });
}
