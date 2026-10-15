import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { createRelay } from './server.mjs';

function connect(base, role, room, id) {
  return new WebSocket(`${base}/${role}?room=${room}${id ? `&id=${id}` : ''}`);
}

test('joins are matched to the selected room and carry binary bytes', async () => {
  const relay = createRelay();
  const port = await relay.listen(0);
  const base = `ws://127.0.0.1:${port}`;
  const room = crypto.randomBytes(32).toString('base64url');
  const host = connect(base, 'host', room);
  await once(host, 'open');
  try {
    const request = once(host, 'message');
    const client = connect(base, 'join', room);
    await once(client, 'open');
    const [{ id }] = [(JSON.parse((await request)[0].toString()))];
    const accepted = connect(base, 'accept', room, id);
    await once(accepted, 'open');
    const forward = once(accepted, 'message');
    client.send(Buffer.from([0, 1, 2, 255]));
    assert.deepEqual(Buffer.from((await forward)[0]), Buffer.from([0, 1, 2, 255]));
    const back = once(client, 'message');
    accepted.send(Buffer.from('reply'));
    assert.equal((await back)[0].toString(), 'reply');
    client.terminate();
    accepted.terminate();
  } finally { host.terminate(); await relay.close(); }
});

test('unknown rooms, malformed tokens and duplicate hosts are rejected', async () => {
  const relay = createRelay();
  const port = await relay.listen(0);
  const base = `ws://127.0.0.1:${port}`;
  const room = crypto.randomBytes(32).toString('base64url');
  async function rejected(role, token) {
    const ws = connect(base, role, token);
    const error = await once(ws, 'error');
    assert.match(error[0].message, /Unexpected server response/);
  }
  try {
    await rejected('join', room);
    await rejected('host', 'bad');
    const host = connect(base, 'host', room);
    await once(host, 'open');
    await rejected('host', room);
    host.terminate();
  } finally { await relay.close(); }
});
