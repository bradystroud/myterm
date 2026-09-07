// Integration tests for the MyTerm relay.
//
// Starts `wrangler dev` (local mode) as a child process against the real
// Worker + Durable Object code, then drives the protocol over real
// WebSocket connections using Node's built-in WebSocket and http clients.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const relayDir = path.resolve(__dirname, "..");

const PORT = 8799;
const BASE_HTTP = `http://127.0.0.1:${PORT}`;
const BASE_WS = `ws://127.0.0.1:${PORT}`;

let wranglerProcess;

function randomId(prefix) {
  return `${prefix}${crypto.randomUUID().replace(/-/g, "")}`.slice(0, 32);
}

async function waitForServer(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${BASE_HTTP}/`);
      if (res.status === 200) {
        const text = await res.text();
        if (text === "myterm relay") return;
      }
    } catch (err) {
      lastError = err;
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`relay did not come up in time: ${lastError}`);
}

/** Waits for a WebSocket to reach OPEN, or rejects on error/unexpected close. */
function waitOpen(ws) {
  return new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener("error", (e) => reject(new Error(`ws error: ${e.message ?? e}`)), {
      once: true,
    });
  });
}

/** Waits for a single close event, resolving with { code, reason }. */
function waitClose(ws) {
  return new Promise((resolve) => {
    ws.addEventListener(
      "close",
      (e) => resolve({ code: e.code, reason: e.reason }),
      { once: true },
    );
  });
}

/**
 * Collects every message a socket receives, from the moment this is called, so a test can read
 * them in order without racing the relay: a WebSocket keeps nothing for a listener attached late.
 * Text frames are parsed as JSON; binary frames become Uint8Arrays. Blob reads are chained, so a
 * slow one can never overtake the next.
 */
function inbox(ws) {
  const queue = [];
  const waiters = [];
  let chain = Promise.resolve();
  ws.addEventListener("message", (e) => {
    chain = chain.then(async () => {
      let value;
      if (typeof e.data === "string") value = JSON.parse(e.data);
      else if (e.data instanceof Blob) value = new Uint8Array(await e.data.arrayBuffer());
      else value = new Uint8Array(e.data);
      if (waiters.length) waiters.shift()(value);
      else queue.push(value);
    });
  });
  return {
    next: () => (queue.length ? Promise.resolve(queue.shift()) : new Promise((r) => waiters.push(r))),
  };
}

before(async () => {
  wranglerProcess = spawn(
    "npx",
    ["wrangler", "dev", "--port", String(PORT), "--local", "--log-level", "warn"],
    {
      cwd: relayDir,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, CI: "true" },
    },
  );

  let stderrBuf = "";
  wranglerProcess.stderr.on("data", (chunk) => {
    stderrBuf += chunk.toString();
  });
  wranglerProcess.on("exit", (code, signal) => {
    if (code !== null && code !== 0) {
      console.error(`wrangler dev exited early (code=${code} signal=${signal}):\n${stderrBuf}`);
    }
  });

  await waitForServer(60_000);
});

after(async () => {
  if (!wranglerProcess) return;
  wranglerProcess.kill("SIGTERM");
  await new Promise((resolve) => {
    wranglerProcess.once("exit", resolve);
    setTimeout(resolve, 5_000);
  });
});

test("GET /v1/health reports ok", async () => {
  const res = await fetch(`${BASE_HTTP}/v1/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(body, { ok: true });
});

test("host registers, device connects, bytes flow both ways, close propagates", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);

  const openMsg = await hostInbox.next();
  assert.equal(openMsg.type, "open");
  assert.equal(typeof openMsg.session, "string");
  assert.match(openMsg.session, /^[0-9a-f]{32}$/);

  const hostSession = new WebSocket(
    `${BASE_WS}/v1/host/${id}/session/${openMsg.session}`,
    { headers: { "X-MyTerm-Host-Key": key } },
  );
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);

  // device -> host: sent as a Uint8Array view (what a real client sends), forwarded byte-for-byte.
  const deviceToHost = new TextEncoder().encode("hello from device");
  device.send(deviceToHost);
  const receivedByHost = await sessionInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedByHost), Buffer.from(deviceToHost));

  // host -> device
  const hostToDevice = new TextEncoder().encode("hello from host");
  hostSession.send(hostToDevice);
  const receivedByDevice = await deviceInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedByDevice), Buffer.from(hostToDevice));

  // closing the device propagates a 1000 "peer closed" to the host session socket.
  const hostSideClose = waitClose(hostSession);
  device.close(1000, "done");
  const closeEvent = await hostSideClose;
  assert.equal(closeEvent.code, 1000);
  assert.equal(closeEvent.reason, "peer closed");

  host.close();
});

test("buffered device frames sent before the host answers are flushed in order", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);

  const openMsg = await hostInbox.next();

  // Send frames before the host session socket exists; they must be buffered and flushed in order.
  device.send(new TextEncoder().encode("first"));
  device.send(new TextEncoder().encode("second"));

  // Give the relay a beat to buffer both frames before the host connects.
  await new Promise((r) => setTimeout(r, 200));

  const hostSession = new WebSocket(
    `${BASE_WS}/v1/host/${id}/session/${openMsg.session}`,
    { headers: { "X-MyTerm-Host-Key": key } },
  );
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);

  const first = await sessionInbox.next();
  assert.equal(new TextDecoder().decode(first), "first");
  const second = await sessionInbox.next();
  assert.equal(new TextDecoder().decode(second), "second");

  device.close();
  host.close();
});

test("forwards arbitrary binary payloads byte-for-byte, as both a Uint8Array view and a plain ArrayBuffer", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);

  const openMsg = await hostInbox.next();
  const hostSession = new WebSocket(
    `${BASE_WS}/v1/host/${id}/session/${openMsg.session}`,
    { headers: { "X-MyTerm-Host-Key": key } },
  );
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);

  // Every byte value 0x00-0xff, sent as a Uint8Array view over a larger backing buffer (with a
  // non-zero byteOffset) — this is the exact shape that produced empty frames before the fix.
  const backing = new Uint8Array(8 + 256);
  for (let i = 0; i < 256; i++) backing[8 + i] = i;
  const allBytesView = new Uint8Array(backing.buffer, 8, 256);

  device.send(allBytesView);
  const receivedAllBytes = await sessionInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedAllBytes), Buffer.from(allBytesView));

  // A batch of cryptographically random bytes, sent as a plain ArrayBuffer, device -> host.
  const randomPayload = new Uint8Array(4096);
  crypto.getRandomValues(randomPayload);
  device.send(randomPayload.buffer);
  const receivedRandom = await sessionInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedRandom), Buffer.from(randomPayload));

  // Same, host -> device, as a Uint8Array view.
  const replyPayload = new Uint8Array(4096);
  crypto.getRandomValues(replyPayload);
  hostSession.send(replyPayload);
  const receivedReply = await deviceInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedReply), Buffer.from(replyPayload));

  device.close();
  host.close();
});

test("device gets 4004 when no host is connected for the id", async () => {
  const id = randomId("id-");
  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  const closeEvent = await waitClose(device);
  assert.equal(closeEvent.code, 4004);
  assert.equal(closeEvent.reason, "host offline");
});

test("host session socket with the wrong key is rejected with HTTP 403", async () => {
  const id = randomId("id-");
  const key = randomId("key-");
  const wrongKey = randomId("wrong-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);
  const openMsg = await hostInbox.next();

  const status = await attemptUpgradeAndGetStatus(
    `/v1/host/${id}/session/${openMsg.session}`,
    { "X-MyTerm-Host-Key": wrongKey },
  );
  assert.equal(status, 403);

  device.close();
  host.close();
});

/**
 * Performs a raw HTTP WebSocket-upgrade handshake and resolves with the status
 * code the server responded with. Node's global WebSocket does not expose the
 * rejecting HTTP status directly, so this uses node:http instead.
 */
function attemptUpgradeAndGetStatus(pathname, extraHeaders) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: "127.0.0.1",
      port: PORT,
      path: pathname,
      method: "GET",
      headers: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": Buffer.from(crypto.randomUUID()).toString("base64").slice(0, 24),
        ...extraHeaders,
      },
    });

    req.on("response", (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    req.on("upgrade", (res) => {
      resolve(res.statusCode);
    });
    req.on("error", reject);
    req.end();
  });
}
