// ccm-testkey.js - validate one API key using Node's HTTP stack (the SAME stack claude-code-router
// uses), so it succeeds against hosts that PowerShell's .NET client stalls on (Cloudflare/TLS).
// Usage:  <key on stdin> | node ccm-testkey.js <url>
// Prints:  "STATUS <httpcode>"  on any HTTP response, or  "ERR <reason>"  on a network failure.
'use strict';
const https = require('https'), http = require('http'), url = require('url');
const target = process.argv[2] || '';
let key = '';
process.stdin.on('data', d => { key += d; });
process.stdin.on('end', () => {
  key = key.trim();
  let t; try { t = url.parse(target); } catch (e) { process.stdout.write('ERR badurl\n'); process.exit(0); return; }
  const lib = t.protocol === 'https:' ? https : http;
  let finished = false;
  const done = (s) => { if (finished) return; finished = true; process.stdout.write(s + '\n'); process.exit(0); };
  try {
    const req = lib.request({
      protocol: t.protocol, hostname: t.hostname, port: t.port || (t.protocol === 'https:' ? 443 : 80),
      path: t.path, method: 'GET',
      headers: { 'authorization': 'Bearer ' + key, 'user-agent': 'Mozilla/5.0 (CCM key test)', 'accept': 'application/json' }
    }, (r) => { done('STATUS ' + r.statusCode); r.resume(); });
    req.on('error', (e) => done('ERR ' + (e.code || e.message || 'error')));
    req.setTimeout(12000, () => { try { req.destroy(); } catch (x) {} done('ERR timeout'); });
    req.end();
  } catch (e) { done('ERR ' + (e.message || 'exception')); }
});
