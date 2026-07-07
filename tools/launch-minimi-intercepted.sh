#!/usr/bin/env bash
# Launch Minimi with BOTH interception layers so all its traffic hits HTTP Toolkit:
#   1. NODE_OPTIONS require-hook  -> catches Node `node-fetch` POSTs (/api/memory/*)
#   2. --proxy-server flag        -> catches Chromium network-service GETs (/api/billing/*)
# HTTP Toolkit must be OPEN first (its proxy listens on 8000, CA already trusted in system keychain).
set -euo pipefail

PROXY_PORT="${1:-8000}"
HTK_DIR="/Applications/HTTP Toolkit.app/Contents/Resources/httptoolkit-server/overrides/js"
HOOK="$HTK_DIR/prepend-node.js"
CA="/Users/mafex/Library/Preferences/httptoolkit/ca.pem"
MINIMI="/Applications/Minimi.app/Contents/MacOS/Minimi"

[ -f "$HOOK" ] || { echo "Hook not found: $HOOK"; exit 1; }
[ -f "$CA" ]   || { echo "CA not found: $CA"; exit 1; }

# Make sure the proxy is actually up.
if ! lsof -nP -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Nothing listening on port $PROXY_PORT — open HTTP Toolkit first."; exit 1
fi

echo "Launching Minimi with Node hook + Chromium proxy on :$PROXY_PORT ..."

# Node layer: require the hook, trust the CA, force proxy for global-agent + std env.
export NODE_OPTIONS="--require \"$HOOK\""
export NODE_EXTRA_CA_CERTS="$CA"
export HTTP_TOOLKIT_ACTIVE="true"
export HTTP_PROXY="http://127.0.0.1:$PROXY_PORT"
export HTTPS_PROXY="http://127.0.0.1:$PROXY_PORT"
export http_proxy="http://127.0.0.1:$PROXY_PORT"
export https_proxy="http://127.0.0.1:$PROXY_PORT"
export GLOBAL_AGENT_HTTP_PROXY="http://127.0.0.1:$PROXY_PORT"

# Chromium layer: route the network service through the same proxy, but let
# loopback (the proxy itself) bypass so we don't loop.
# Detached (nohup + &) so closing this terminal does NOT kill Minimi.
nohup "$MINIMI" \
  --proxy-server="127.0.0.1:$PROXY_PORT" \
  --proxy-bypass-list="<-loopback>" \
  >/tmp/minimi-intercept.log 2>&1 &

MPID=$!
echo "Minimi launched detached (pid $MPID). Logs: /tmp/minimi-intercept.log"
echo "Give it ~5s, then open a NEW page or send a message to trigger the memory POSTs."
disown 2>/dev/null || true
