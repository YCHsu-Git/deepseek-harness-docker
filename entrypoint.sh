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

# DeepSeek's own API is what --host 0.0.0.0 obviously can't affect: a failure
# to reach it here is a network problem (firewall/GFW/proxy), not a dsh bug.
# Set HTTP_PROXY/HTTPS_PROXY if outbound HTTPS needs a proxy to leave the host.
if code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 https://api.deepseek.com/v1/models 2>&1); then
  echo "entrypoint: probed https://api.deepseek.com -> HTTP $code"
else
  echo "entrypoint: could not reach https://api.deepseek.com ($code) -- outbound network/DNS/firewall problem, not a dsh config problem; set HTTP_PROXY/HTTPS_PROXY if this host needs a proxy for outbound HTTPS" >&2
fi

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

# Pre-seed a custom Ollama provider when requested, and make it the default
# model for new sessions so a fresh deployment never reaches for DeepSeek. A
# real YAML merge needs a parser we don't have, so each key below is only ever
# added whole, as one flow-style line safe to append to any existing mapping;
# a settings.yaml that already has that top-level key is left untouched.
seed_yaml_key() {
  local key="$1" line="$2" desc="$3"
  if [ ! -f "$DSH_HOME/settings.yaml" ] || ! grep -q "$key" "$DSH_HOME/settings.yaml"; then
    printf '%s\n' "$line" >> "$DSH_HOME/settings.yaml"
    echo "entrypoint: seeded $desc"
  else
    echo "entrypoint: settings.yaml already has $key; leaving it alone (edit it by hand or via the Models page)" >&2
  fi
}

if [ -n "${OLLAMA_BASE_URL:-}" ]; then
  mkdir -p "$DSH_HOME"
  touch "$DSH_HOME/settings.yaml"
  export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}"
  first_model=""
  models_json=""
  for model in $(echo "${OLLAMA_MODELS:-llama3.1}" | tr ',' ' '); do
    [ -z "$first_model" ] && first_model="$model"
    [ -n "$models_json" ] && models_json+=", "
    models_json+="{id: ${model}}"
  done
  ollama_line="llm-pi-ai: {providers: {ollama: {apiKeyEnv: OLLAMA_API_KEY, api: openai-completions, baseURL: \"${OLLAMA_BASE_URL}\", compat: {supportsDeveloperRole: false, maxTokensField: max_tokens}, models: [${models_json}]}}}"
  default_model_line="agent-default-model: {provider: ollama, model: ${first_model}}"

  seed_yaml_key '^llm-pi-ai:' "$ollama_line" "the ollama provider (baseURL=$OLLAMA_BASE_URL)"
  seed_yaml_key '^agent-default-model:' "$default_model_line" "ollama/$first_model as the default model"

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
