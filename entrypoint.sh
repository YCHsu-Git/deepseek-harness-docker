#!/usr/bin/env bash
# dsh only binds its web app to 127.0.0.1:3080. Nginx proxies a different
# external port (8080) to it and normalizes Host/Origin to the loopback
# authority accepted by dsh's API trust check.
set -euo pipefail

# Let `docker run <image> bash` (or sh) drop straight into a shell instead of
# being passed as an argument to the dsh CLI below.
case "${1:-}" in
  bash|sh) exec "$@" ;;
esac

# set DEBUG=1 to trace every command this script runs
if [ "${DEBUG:-}" = "1" ] || [ "${DEBUG:-}" = "true" ]; then
  set -x
fi

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
  # pi-ai only defaults a request's max_tokens from a *model's own* maxTokens
  # (route-level defaultMaxTokens only sizes catalog capability and is kept
  # out of request defaults by design), so the cap has to be set per model
  # here for "Output token limit reached" to actually go away.
  for model in $(echo "${OLLAMA_MODELS:-llama3.1}" | tr ',' ' '); do
    [ -z "$first_model" ] && first_model="$model"
    [ -n "$models_json" ] && models_json+=", "
    models_json+="{id: ${model}, maxTokens: ${OLLAMA_MAX_TOKENS:-128000}}"
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

# Auto-install the dsh-market plugin marketplace (https://github.com/dsh-market/dsh-market)
# into the web profile. Skipped once it's already recorded there, or via SKIP_DSH_MARKET=1.
if [ "${1:-}" = "web" ] && [ "${SKIP_DSH_MARKET:-}" != "1" ]; then
  market_pkg_json="$DSH_HOME/profiles/web/package.json"
  if [ ! -f "$market_pkg_json" ] || ! grep -q '"dshmarket"' "$market_pkg_json"; then
    echo "entrypoint: installing dsh-market plugin into the web profile"
    node apps/cli/lib/bin.js --profile web --dump-default-config >/dev/null 2>&1 || true
    if node apps/cli/lib/bin.js plugin --profile web add dshmarket; then
      echo "entrypoint: dsh-market installed"
    else
      echo "entrypoint: failed to install dsh-market plugin; continuing without it" >&2
    fi
  fi
fi

nginx_pid=""
# The compiled CLI keeps the launcher and profile plugins in the same lib/
# module plane. `pnpm dsh` starts the TypeScript source entry and can split
# module-scoped symbols from plugins resolved through lib/.
# dsh's http.Server starts accepting TCP connections well before its Cordis
# plugin tree (including the /api/remote.mux WebSocket route) finishes
# mounting, so a bare TCP-connect readiness check leaves a window where nginx
# forwards traffic into a socket dsh resets mid-handshake. `dsh web:` is only
# printed once the full Loader tree settles, so tee stdout to a file and wait
# for that line instead; process substitution keeps $! as dsh's own pid.
dsh_log="$(mktemp)"
node apps/cli/lib/bin.js "$@" "${extra_args[@]}" > >(tee "$dsh_log") 2>&1 &
dsh_pid=$!

cleanup() {
  [ -z "$nginx_pid" ] || kill -TERM "$nginx_pid" 2>/dev/null || true
  kill -TERM "$dsh_pid" 2>/dev/null || true
  [ -z "$nginx_pid" ] || wait "$nginx_pid" 2>/dev/null || true
  wait "$dsh_pid" 2>/dev/null || true
  rm -f "$dsh_log"
}
trap cleanup TERM INT EXIT

# Bail out instead of retrying forever if dsh exited (bad config, etc.). Cap
# the wait in case a future dsh version changes this exact wording, falling
# back to the old (racy but bounded) TCP check rather than hanging forever.
boot_wait=0
until grep -q '^dsh web:' "$dsh_log" 2>/dev/null; do
  if ! kill -0 "$dsh_pid" 2>/dev/null; then
    echo "entrypoint: dsh exited before it started listening; see the log above" >&2
    exit 1
  fi
  if [ "$boot_wait" -ge 120 ]; then
    echo "entrypoint: dsh did not print its startup line within 60s; falling back to a plain TCP check" >&2
    until (echo > /dev/tcp/127.0.0.1/3080) 2>/dev/null; do
      kill -0 "$dsh_pid" 2>/dev/null || { echo "entrypoint: dsh exited before it started listening; see the log above" >&2; exit 1; }
      sleep 0.5
    done
    break
  fi
  sleep 0.5
  boot_wait=$((boot_wait + 1))
done

nginx -g 'daemon off;' &
nginx_pid=$!

wait -n "$dsh_pid" "$nginx_pid"
