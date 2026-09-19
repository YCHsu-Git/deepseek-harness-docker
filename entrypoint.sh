#!/usr/bin/env bash
# dsh only binds its web app to 127.0.0.1:3080. A socket bound to 0.0.0.0
# cannot share a port with one already bound to 127.0.0.1 (the wildcard
# overlaps the specific address), so relay a *different* external port
# (LISTEN_PORT, default 8080) to 127.0.0.1:3080 with socat.
set -euo pipefail

LISTEN_PORT="${LISTEN_PORT:-8080}"
DSH_HOME="${DSH_HOME:-/root/.dsh}"

# The browser-trust fence 403s any request whose Host header isn't loopback
# or in --trusted-host, so a non-loopback host:port needs to be declared here.
# --trusted-host takes a variadic list; repeating the flag would just replace
# the previous occurrence, so pass every host in one invocation. dsh rejects
# an unbracketed IPv6 literal outright (crashing startup), so drop those here
# too, defense-in-depth against whatever produced TRUSTED_HOSTS.
extra_args=()
if [ -n "${TRUSTED_HOSTS:-}" ]; then
  IFS=',' read -ra trusted_hosts <<< "$TRUSTED_HOSTS"
  filtered_hosts=()
  for host in "${trusted_hosts[@]}"; do
    case "$host" in
      \[*) filtered_hosts+=("$host") ;;
      *:*:*) echo "entrypoint: skipping unbracketed IPv6 trusted host: $host" >&2 ;;
      *) filtered_hosts+=("$host") ;;
    esac
  done
  if [ "${#filtered_hosts[@]}" -gt 0 ]; then
    extra_args+=(--trusted-host "${filtered_hosts[@]}")
    echo "entrypoint: trusted hosts: ${filtered_hosts[*]}"
  fi
fi

# Pre-seed a custom Ollama provider on first run only, so an existing
# settings.yaml (or a later edit through the Models page) is never overwritten.
if [ -n "${OLLAMA_BASE_URL:-}" ] && [ ! -f "$DSH_HOME/settings.yaml" ]; then
  mkdir -p "$DSH_HOME"
  export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}"
  {
    echo "llm-pi-ai:"
    echo "  providers:"
    echo "    ollama:"
    echo "      apiKeyEnv: OLLAMA_API_KEY"
    echo "      api: openai-completions"
    echo "      baseURL: ${OLLAMA_BASE_URL}"
    echo "      compat:"
    echo "        supportsDeveloperRole: false"
    echo "        maxTokensField: max_tokens"
    echo "      models:"
    for model in $(echo "${OLLAMA_MODELS:-llama3.1}" | tr ',' ' '); do
      echo "        - id: ${model}"
    done
  } > "$DSH_HOME/settings.yaml"
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
