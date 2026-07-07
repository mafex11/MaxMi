// Attach to Minimi's Electron MAIN process via the Node inspector (--inspect=9229)
// and monkey-patch global fetch so every request/response to projectminimi.com is
// written to /tmp/minimi-net.log — bypassing proxies, CAs, and the dual network stack.
//
// Prereq: Minimi launched with --inspect=9229.
// Usage: node inspect-minimi-net.mjs
import http from 'http';

const HOST_MATCH = 'projectminimi.com';
const LOG = '/tmp/minimi-net.log';

// 1. Discover the main-process inspector ws URL.
const targets = await new Promise((res, rej) => {
  http.get('http://127.0.0.1:9229/json/list', r => {
    let b = ''; r.on('data', c => b += c); r.on('end', () => res(JSON.parse(b)));
  }).on('error', rej);
});
const wsUrl = targets[0]?.webSocketDebuggerUrl;
if (!wsUrl) { console.error('No inspector target. Is Minimi running with --inspect=9229?'); process.exit(1); }

const ws = new WebSocket(wsUrl);
let id = 0;
const send = (method, params = {}) => { const i = ++id; ws.send(JSON.stringify({ id: i, method, params })); return i; };

// 2. The code injected INTO Minimi's main process. It wraps fetch and appends
//    JSON lines to the log. Truncates bodies to keep the log sane.
const injection = `
(() => {
  if (globalThis.__minimiNetHooked) return 'already-hooked';
  globalThis.__minimiNetHooked = true;
  const fs = require('fs');
  const LOG = ${JSON.stringify(LOG)};
  const MATCH = ${JSON.stringify(HOST_MATCH)};
  const cap = (s, n) => (typeof s === 'string' && s.length > n ? s.slice(0, n) + '…<+' + (s.length - n) + '>' : s);
  const line = (obj) => { try { fs.appendFileSync(LOG, JSON.stringify(obj) + '\\n'); } catch (e) {} };
  const origFetch = globalThis.fetch;
  if (!origFetch) return 'no-global-fetch';
  globalThis.fetch = async (input, init) => {
    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
    const isTarget = url.includes(MATCH);
    let reqBody = null;
    if (isTarget && init && init.body != null) {
      try { reqBody = typeof init.body === 'string' ? init.body : JSON.stringify(init.body); } catch (e) { reqBody = '<unserializable>'; }
    }
    const method = (init && init.method) || 'GET';
    const res = await origFetch(input, init);
    if (isTarget) {
      let respBody = null;
      try { respBody = await res.clone().text(); } catch (e) { respBody = '<clone-failed>'; }
      line({ t: new Date().toISOString(), method, url, status: res.status,
             reqBody: cap(reqBody, 8000), respBody: cap(respBody, 8000) });
    }
    return res;
  };
  return 'hooked-ok';
})();
`;

ws.onopen = () => { send('Runtime.enable'); send('Runtime.evaluate', { expression: injection, awaitPromise: true, returnByValue: true }); };
ws.onmessage = e => {
  const m = JSON.parse(e.data);
  if (m.id === 2 || (m.result && m.result.result)) {
    const v = m.result?.result?.value;
    if (v) { console.log('Injection result:', v); console.log('Now trigger a capture. Tailing', LOG); }
  }
};
ws.onerror = e => { console.error('ws error', e.message); process.exit(1); };
// Keep alive so the inspector session (and the hook) stays attached.
setInterval(() => {}, 1 << 30);
