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
extra_args=()
if [ -n "${TRUSTED_HOSTS:-}" ]; then
  IFS=',' read -ra trusted_hosts <<< "$TRUSTED_HOSTS"
  for host in "${trusted_hosts[@]}"; do
    extra_args+=(--trusted-host "$host")
  done
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

until (echo > /dev/tcp/127.0.0.1/3080) 2>/dev/null; do
  sleep 0.5
done

socat TCP-LISTEN:"$LISTEN_PORT",fork,reuseaddr TCP:127.0.0.1:3080 &
socat_pid=$!

wait -n "$dsh_pid" "$socat_pid"
