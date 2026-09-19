#!/usr/bin/env bash
# dsh only binds its web app to 127.0.0.1:3080. A socket bound to 0.0.0.0
# cannot share a port with one already bound to 127.0.0.1 (the wildcard
# overlaps the specific address), so relay a *different* external port
# (LISTEN_PORT, default 8080) to 127.0.0.1:3080 with socat.
set -euo pipefail

# set DEBUG=1 to trace every command this script runs
if [ "${DEBUG:-}" = "1" ] || [ "${DEBUG:-}" = "true" ]; then
  set -x
fi

LISTEN_PORT="${LISTEN_PORT:-8080}"
DSH_HOME="${DSH_HOME:-/root/.dsh}"

# The browser-trust fence 403s any request whose Host header isn't loopback
# or in --trusted-host, so a non-loopback host:port needs to be declared here.
# --trusted-host takes a variadic list; repeating the flag would just replace
# the previous occurrence, so pass every host in one invocation. dsh rejects an
# unbracketed IPv6 literal outright (crashing startup) and has no syntax for a
# zone id, so bracket bare IPv6 and drop link-local/zone-id addresses here too
# -- defense-in-depth against whatever produced TRUSTED_HOSTS.
extra_args=()
if [ -n "${TRUSTED_HOSTS:-}" ]; then
  IFS=',' read -ra trusted_hosts <<< "$TRUSTED_HOSTS"
  filtered_hosts=()
  for host in "${trusted_hosts[@]}"; do
    case "$host" in
      \[*) filtered_hosts+=("$host") ;;
      *%*) echo "entrypoint: skipping link-local trusted host: $host" >&2 ;;
      fe80:*) echo "entrypoint: skipping link-local trusted host: $host" >&2 ;;
      *:*:*) filtered_hosts+=("[$host]") ;;
      *) filtered_hosts+=("$host") ;;
    esac
  done
  if [ "${#filtered_hosts[@]}" -gt 0 ]; then
    extra_args+=(--trusted-host "${filtered_hosts[@]}")
    echo "entrypoint: trusted hosts: ${filtered_hosts[*]}"
  fi
fi

# Pre-seed a custom Ollama provider when requested. A real YAML merge needs a
# parser we don't have, so this only ever adds the whole top-level
# `llm-pi-ai:` key (as one flow-style line, safe to append to any existing
# mapping) and refuses to touch a settings.yaml that already has that key.
if [ -n "${OLLAMA_BASE_URL:-}" ]; then
  mkdir -p "$DSH_HOME"
  export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}"
  models_json=""
  for model in $(echo "${OLLAMA_MODELS:-llama3.1}" | tr ',' ' '); do
    [ -n "$models_json" ] && models_json+=", "
    models_json+="{id: ${model}}"
  done
  ollama_line="llm-pi-ai: {providers: {ollama: {apiKeyEnv: OLLAMA_API_KEY, api: openai-completions, baseURL: \"${OLLAMA_BASE_URL}\", compat: {supportsDeveloperRole: false, maxTokensField: max_tokens}, models: [${models_json}]}}}"

  if [ ! -f "$DSH_HOME/settings.yaml" ]; then
    echo "$ollama_line" > "$DSH_HOME/settings.yaml"
    echo "entrypoint: seeded Ollama provider (baseURL=$OLLAMA_BASE_URL) in a new settings.yaml"
  elif grep -q '^llm-pi-ai:' "$DSH_HOME/settings.yaml"; then
    echo "entrypoint: settings.yaml already has an llm-pi-ai section; leaving it alone (add the ollama provider by hand or via the Models page)" >&2
  else
    printf '\n%s\n' "$ollama_line" >> "$DSH_HOME/settings.yaml"
    echo "entrypoint: appended Ollama provider (baseURL=$OLLAMA_BASE_URL) to existing settings.yaml"
  fi

  # Tell config problems apart from network problems: probe the endpoint
  # itself, independent of whatever settings.yaml ended up with above.
  models_url="${OLLAMA_BASE_URL%/}/models"
  if code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$models_url" 2>&1); then
    echo "entrypoint: probed $models_url -> HTTP $code"
  else
    echo "entrypoint: could not reach $models_url ($code) -- check the container is on the same docker network as Ollama, or that OLLAMA_BASE_URL/OLLAMA_CONTAINER is correct" >&2
  fi
fi

if [ "${DEBUG:-}" = "1" ] || [ "${DEBUG:-}" = "true" ]; then
  echo "entrypoint: --- debug: network ---"
  ip -4 addr show 2>&1 | sed 's/^/entrypoint: /'
  echo "entrypoint: --- debug: settings.yaml ---"
  cat "$DSH_HOME/settings.yaml" 2>&1 | sed 's/^/entrypoint: /'
fi

pnpm dsh "$@" "${extra_args[@]}" &
dsh_pid=$!

cleanup() {
  kill -TERM "$dsh_pid" 2>/dev/null || true
  wait "$dsh_pid" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# Bail out instead of retrying forever if dsh exited (bad config, etc.).
until (echo > /dev/tcp/127.0.0.1/3080) 2>/dev/null; do
  if ! kill -0 "$dsh_pid" 2>/dev/null; then
    echo "entrypoint: dsh exited before it started listening; see the log above" >&2
    exit 1
  fi
  sleep 0.5
done

socat TCP-LISTEN:"$LISTEN_PORT",fork,reuseaddr TCP:127.0.0.1:3080 &
socat_pid=$!

wait -n "$dsh_pid" "$socat_pid"
