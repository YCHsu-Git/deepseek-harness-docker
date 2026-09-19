#!/usr/bin/env bash
# dsh only binds its web app to 127.0.0.1:3080. A socket bound to 0.0.0.0
# cannot share a port with one already bound to 127.0.0.1 (the wildcard
# overlaps the specific address), so relay a *different* external port
# (LISTEN_PORT, default 8080) to 127.0.0.1:3080 with socat.
set -euo pipefail

LISTEN_PORT="${LISTEN_PORT:-8080}"

pnpm dsh "$@" &
dsh_pid=$!

cleanup() {
  kill -TERM "$dsh_pid" 2>/dev/null || true
  wait "$dsh_pid" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

until (echo > /dev/tcp/127.0.0.1/3080) 2>/dev/null; do
  sleep 0.5
done

socat TCP-LISTEN:"$LISTEN_PORT",fork,reuseaddr TCP:127.0.0.1:3080 &
socat_pid=$!

wait -n "$dsh_pid" "$socat_pid"
