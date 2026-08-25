#!/bin/bash
# Boots a throwaway nodeterm Server Edition for the E2E UI test (ConnectFlowUITests):
# port 8444, fresh data dir seeded with project "Sim Test" + terminal node "simnode1",
# password simtest-pass-8444. Requires a built nodeterm checkout (out/server/main.cjs).
set -eu
NODETERM_REPO="${NODETERM_REPO:-$HOME/git/nodeterm}"
DATA_DIR="${DATA_DIR:-/tmp/nodeterm-uitest-data}"
mkdir -p "$DATA_DIR"
cat > "$DATA_DIR/workspace.json" << 'JSON'
{"version":3,"activeProjectId":"proj-simtest","entries":[{"id":"proj-simtest","name":"Sim Test","color":"#A78BFA","project":{"id":"proj-simtest","name":"Sim Test","color":"#A78BFA","viewport":{"x":0,"y":0,"zoom":1},"nodes":[{"id":"simnode1","kind":"terminal","position":{"x":100,"y":100},"size":{"width":520,"height":360},"title":"Sim Shell","color":"#A78BFA","group":null}]}}]}
JSON
cd "$NODETERM_REPO"
NODETERM_HOST=127.0.0.1 NODETERM_PORT=8444 NODETERM_DATA_DIR="$DATA_DIR" \
NODETERM_SERVER_PASSWORD='simtest-pass-8444' NODETERM_TELEMETRY_DISABLED=1 DO_NOT_TRACK=1 \
exec node out/server/main.cjs
