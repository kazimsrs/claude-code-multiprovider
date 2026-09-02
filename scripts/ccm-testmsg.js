// ccm-testmsg.js - validate a key against an Anthropic-compatible gateway by POSTing a tiny
// /v1/messages request through Node's HTTP stack (succeeds on Cloudflare-fronted hosts that
// PowerShell's .NET client stalls on). Tries x-api-key first, then Bearer.
// Usage:  <key on stdin> | node ccm-testmsg.js <baseUrl> <model>
// Prints: "OK <scheme> <code>" on success, "STATUS <code> <scheme> <snippet>" on an HTTP error,
//         or "ERR <reason>" on a network failure.
'use strict';
const https = require('https'), http = require('http'), url = require('url');
const base = (process.argv[2] || '').replace(/\/+$/, '');
const model = process.argv[3] || 'claude-3-5-sonnet';
let key = '';
process.stdin.on('data', d => { key += d; });
process.stdin.on('end', () => {
  key = key.trim();
  if (!key)  { process.stdout.write('ERR nokey\n');  process.exit(0); return; }
  if (!base) { process.stdout.write('ERR nobase\n'); process.exit(0); return; }
  let target; try { target = url.parse(base + '/v1/messages'); } catch (e) { process.stdout.write('ERR badurl\n'); process.exit(0); return; }
  const lib = target.protocol === 'https:' ? https : http;
  const body = JSON.stringify({ model: model, max_tokens: 16, messages: [{ role: 'user', content: 'hi' }] });
  const schemes = [['xapikey', { 'x-api-key': key }], ['bearer', { 'authorization': 'Bearer ' + key }]];
  let idx = 0, finished = false;
  const done = (s) => { if (finished) return; finished = true; process.stdout.write(s + '\n'); process.exit(0); };
  function tryScheme() {
    if (idx >= schemes.length) return;
    const pair = schemes[idx++]; const name = pair[0]; const auth = pair[1];
    const headers = Object.assign({ 'content-type': 'application/json', 'anthropic-version': '2023-06-01', 'user-agent': 'Mozilla/5.0 (CCM key test)', 'content-length': Buffer.byteLength(body) }, auth);
    const req = lib.request({ protocol: target.protocol, hostname: target.hostname, port: target.port || (target.protocol === 'https:' ? 443 : 80), path: target.path, method: 'POST', headers: headers }, (r) => {
      let b = ''; r.on('data', d => { if (b.length < 400) b += d.toString('utf8'); }); r.on('error', () => {});
      r.on('end', () => {
        const c = r.statusCode || 0;
        if (c >= 200 && c < 300) { done('OK ' + name + ' ' + c); return; }
        if ((c === 401 || c === 403) && idx < schemes.length) { tryScheme(); return; }  // wrong auth header? try the other
        done('STATUS ' + c + ' ' + name + ' ' + b.replace(/\s+/g, ' ').slice(0, 160));
      });
    });
    req.on('error', (e) => { if (idx < schemes.length) { tryScheme(); return; } done('ERR ' + (e.code || e.message || 'error')); });
    req.setTimeout(15000, () => { try { req.destroy(); } catch (x) {} done('ERR timeout'); });
    req.write(body); req.end();
  }
  tryScheme();
});
