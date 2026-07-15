# Phase 7 secure relay contract

**Client implementation:** complete, 2026-07-15  
**Hosted service:** not provisioned

## Distribution rule

Personal development builds may use an owner-controlled `GEMINI_API_KEY` from local
runtime configuration. A distributed MaxMi bundle must never contain or receive a
reusable Gemini provider key. Distributed builds use the MaxMi relay client and a
revocable per-install bearer credential; provider/model routing stays on the server.

`tools/check-bundle-secrets.sh MaxMi.app` rejects dotenv resources and Google provider
key patterns without printing a discovered credential. It is covered by tests and must
run during release.

## Client contract

The client requires an HTTPS base URL, except loopback HTTP in tests, and sends:

- `POST /v1/generate` with model, prompt, temperature, and optional response MIME type;
- `POST /v1/embed` with model, text, and requested dimensions;
- `Authorization: Bearer <per-install-token>`;
- `X-MaxMi-Relay-Protocol: 1`.

The server responds with `{ "text": "..." }` for generation and
`{ "values": [...] }` for embeddings. The client enforces a 128 KiB request limit,
a 4 MiB response limit, exact embedding dimensions, HTTPS, and fail-closed behavior for
partial/insecure configuration. It never sends `x-goog-api-key` to the MaxMi relay.

The per-install relay token is stored in the login Keychain and can be shared by the
signed app and MCP helper. Environment token loading remains only as a development and
initial-provisioning bridge. Existing source-review, cloud-consent, blocked-source, and
local-only behavior remain ahead of relay calls.

## Server responsibilities still required

The hosted service must implement:

- install registration and short-lived/scoped token issuance;
- token rotation, revocation, and per-install rate limits/quotas;
- maximum request/response enforcement at the edge;
- provider-key isolation and server-side model allowlists;
- abuse controls and bounded metadata-only logs;
- no captured-content retention by default;
- health/status behavior that lets clients degrade to local capture and browsing;
- a privacy disclosure covering transport, processing, retention, and deletion.

## Automated evidence

Tests verify the bearer protocol, absence of the Gemini key header, request size limits,
embedding shape/normalization, insecure or partial configuration failing closed, local
configuration parsing, and bundle secret scanning. The current built app passes the
bundle scan. Revocation, quotas, server retention, and production transport cannot be
accepted until a hosted relay exists.
