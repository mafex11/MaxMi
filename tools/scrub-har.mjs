#!/usr/bin/env node
// Scrub a HTTP Toolkit / mitmproxy HAR export before sharing.
// - Redacts Authorization/token/cookie headers and query params.
// - Truncates large text bodies to a preview so prompt/JSON *shape* survives
//   but your captured screen content does not leak in full.
// - Keeps only requests to hosts we care about (default: projectminimi.com).
//
// Usage:
//   node scrub-har.mjs input.har [output.har] [--host projectminimi.com] [--keep 600]
//
// Then hand the *output* file over. Review it yourself first.

import fs from 'fs';

const args = process.argv.slice(2);
const inPath = args.find(a => !a.startsWith('--')) ?? null;
const outPath = args.filter(a => !a.startsWith('--'))[1] ?? (inPath ? inPath.replace(/\.har$/i, '') + '.scrubbed.har' : null);
const hostFilter = (args[args.indexOf('--host') + 1] && args.includes('--host')) ? args[args.indexOf('--host') + 1] : 'projectminimi.com';
const keep = args.includes('--keep') ? parseInt(args[args.indexOf('--keep') + 1], 10) : 800;

if (!inPath) {
  console.error('Usage: node scrub-har.mjs input.har [output.har] [--host projectminimi.com] [--keep 800]');
  process.exit(1);
}

const SENSITIVE_HEADERS = /^(authorization|cookie|set-cookie|x-api-key|x-auth-token|proxy-authorization)$/i;
const SENSITIVE_PARAMS = /(token|key|secret|password|auth|session|signature)/i;

const redactHeaders = headers =>
  (headers ?? []).map(h =>
    SENSITIVE_HEADERS.test(h.name) ? { ...h, value: '<redacted>' } : h
  );

const redactParams = params =>
  (params ?? []).map(p =>
    SENSITIVE_PARAMS.test(p.name) ? { ...p, value: '<redacted>' } : p
  );

const redactUrl = url => {
  try {
    const u = new URL(url);
    for (const k of [...u.searchParams.keys()]) {
      if (SENSITIVE_PARAMS.test(k)) u.searchParams.set(k, '<redacted>');
    }
    return u.toString();
  } catch { return url; }
};

// Truncate a text body but preserve enough to see prompt templates / JSON keys.
const truncateBody = text => {
  if (typeof text !== 'string') return text;
  if (text.length <= keep) return text;
  return text.slice(0, keep) + `\n…<truncated ${text.length - keep} chars>`;
};

const har = JSON.parse(fs.readFileSync(inPath, 'utf8'));
let entries = har.log?.entries ?? [];
const before = entries.length;

entries = entries
  .filter(e => (e.request?.url ?? '').includes(hostFilter))
  .map(e => {
    if (e.request) {
      e.request.url = redactUrl(e.request.url);
      e.request.headers = redactHeaders(e.request.headers);
      e.request.queryString = redactParams(e.request.queryString);
      if (e.request.postData?.text) e.request.postData.text = truncateBody(e.request.postData.text);
      if (Array.isArray(e.request.cookies)) e.request.cookies = [];
    }
    if (e.response) {
      e.response.headers = redactHeaders(e.response.headers);
      if (e.response.content?.text) e.response.content.text = truncateBody(e.response.content.text);
      if (Array.isArray(e.response.cookies)) e.response.cookies = [];
    }
    return e;
  });

har.log.entries = entries;
fs.writeFileSync(outPath, JSON.stringify(har, null, 2));
console.error(`Scrubbed: kept ${entries.length}/${before} entries (host="${hostFilter}"), bodies truncated to ${keep} chars.`);
console.error(`Wrote ${outPath} — review it before sharing.`);
