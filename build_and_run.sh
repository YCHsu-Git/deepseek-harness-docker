#!/usr/bin/env bash
# Clone deepseek-ai/deepseek-harness, build a Docker image for it, and run the
# container. Run this script on a Linux host with Docker and git installed.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/deepseek-ai/deepseek-harness.git}"
# clone under the directory the script is invoked from (pwd), not $HOME
CLONE_DIR="${CLONE_DIR:-$(pwd)/deepseek-harness}"
IMAGE_NAME="${IMAGE_NAME:-deepseek-harness:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-deepseek-harness}"
DSH_HOME_DIR="${DSH_HOME_DIR:-$HOME/.dsh}"
HOST_PORT="${HOST_PORT:-3080}"
# Set this to the hostname or IP that the browser will actually use. Do not
# include a scheme or port: PUBLIC_HOST=192.0.2.10 ./build_and_run.sh
PUBLIC_HOST="${PUBLIC_HOST:-}"
# set PUSH_IMAGE=true to publish the built image to Docker Hub
PUSH_IMAGE="${PUSH_IMAGE:-false}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-superyc1121/deepseek-harness:latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

for bin in git docker; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: $bin is required but not found in PATH" >&2; exit 1; }
done

# 1. Clone or update the source checkout.
if [ -d "$CLONE_DIR/.git" ]; then
  log "Updating existing checkout at $CLONE_DIR"
  git -C "$CLONE_DIR" fetch --depth 1 origin
  git -C "$CLONE_DIR" reset --hard origin/HEAD
else
  log "Cloning $REPO_URL into $CLONE_DIR"
  git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
fi

# 2. Drop in the container support files next to the checked-out sources.
cp "$SCRIPT_DIR/Dockerfile" "$CLONE_DIR/Dockerfile"
cp "$SCRIPT_DIR/.dockerignore" "$CLONE_DIR/.dockerignore"
cp "$SCRIPT_DIR/entrypoint.sh" "$CLONE_DIR/entrypoint.sh"
cp "$SCRIPT_DIR/nginx.conf" "$CLONE_DIR/nginx.conf"

# 3. Build the image.
log "Building image $IMAGE_NAME"
docker build -t "$IMAGE_NAME" "$CLONE_DIR"

# 4. Optionally push to Docker Hub (requires a prior `docker login`).
if [ "$PUSH_IMAGE" = "true" ] || [ "$PUSH_IMAGE" = "1" ]; then
  log "Tagging $IMAGE_NAME as $REGISTRY_IMAGE and pushing"
  docker tag "$IMAGE_NAME" "$REGISTRY_IMAGE"
  docker push "$REGISTRY_IMAGE"
fi

# 5. Replace any previous container instance.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  log "Removing existing container $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

mkdir -p "$DSH_HOME_DIR"

# dsh only auto-trusts LAN IPs when bound to 0.0.0.0, which it refuses to do
# (see entrypoint.sh), so trusting your host's own address is otherwise
# manual. The trust value must match the browser authority, including port.
# PUBLIC_HOST is therefore the reliable option for a remote host, DNS name,
# VPN address, or reverse proxy. Auto-detection is only a local fallback.
# IPv6 needs brackets and a link-local address needs a zone id dsh can't take,
# so bracket routable IPv6 and drop link-local/zone-id addresses entirely
# (entrypoint.sh repeats this filter as a defense-in-depth backstop).
if [ -z "${TRUSTED_HOSTS:-}" ]; then
  if [ -n "$PUBLIC_HOST" ]; then
    case "$PUBLIC_HOST" in
      \[*\]) public_authority="${PUBLIC_HOST}:${HOST_PORT}" ;;
      *:*) public_authority="[${PUBLIC_HOST}]:${HOST_PORT}" ;;
      *) public_authority="${PUBLIC_HOST}:${HOST_PORT}" ;;
    esac
    TRUSTED_HOSTS="$public_authority"
    log "Trusting PUBLIC_HOST: $TRUSTED_HOSTS"
  else
    auto_hosts="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk -v port="$HOST_PORT" '
    /^$/ { next }
    /%/ { next }
    /^127\./ { next }
    /^::1$/ { next }
    /^fe80:/ { next }
    /:/ { print "[" $0 "]:" port; next }
    { print $0 ":" port }
  ' | paste -sd, -)"
    if [ -n "$auto_hosts" ]; then
      TRUSTED_HOSTS="$auto_hosts"
      log "TRUSTED_HOSTS not set; auto-detected browser authorities: $TRUSTED_HOSTS"
    fi
  fi
fi

if [ -z "$PUBLIC_HOST" ]; then
  PUBLIC_HOST="$(hostname 2>/dev/null || true)"
  if [ -n "$PUBLIC_HOST" ]; then
    hostname_authority="${PUBLIC_HOST}:${HOST_PORT}"
    TRUSTED_HOSTS="${TRUSTED_HOSTS:+${TRUSTED_HOSTS},}${hostname_authority}"
    log "Also trusting the printed hostname: $hostname_authority"
  fi
fi

# Resolve an Ollama container's IP by name so it works over plain container
# IPs (the default bridge routes those without any --network/DNS setup).
if [ -z "${OLLAMA_BASE_URL:-}" ] && [ -n "${OLLAMA_CONTAINER:-}" ]; then
  ollama_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$OLLAMA_CONTAINER" 2>/dev/null | head -n1)"
  if [ -n "$ollama_ip" ]; then
    OLLAMA_BASE_URL="http://$ollama_ip:${OLLAMA_PORT:-11434}/v1"
    log "OLLAMA_BASE_URL not set; resolved container $OLLAMA_CONTAINER to $OLLAMA_BASE_URL"
  else
    log "warning: could not resolve an IP for OLLAMA_CONTAINER=$OLLAMA_CONTAINER"
  fi
fi

# 6. Run the container. The image relays dsh's 127.0.0.1:3080-only listener
#    to 0.0.0.0:8080 internally (see entrypoint.sh), so a normal port mapping
#    exposes it on the host's 0.0.0.0:$HOST_PORT.
run_args=(
  -d
  --name "$CONTAINER_NAME"
  -p "0.0.0.0:$HOST_PORT:8080"
  --restart unless-stopped
  -v "$DSH_HOME_DIR:/root/.dsh"
)
[ -n "${DEEPSEEK_API_KEY:-}" ] && run_args+=(-e "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY")
# non-loopback host:port your browser uses, e.g. TRUSTED_HOSTS=203.0.113.10:3080
[ -n "${TRUSTED_HOSTS:-}" ] && run_args+=(-e "TRUSTED_HOSTS=$TRUSTED_HOSTS")
# set these if reaching api.deepseek.com from this host needs a proxy
[ -n "${HTTP_PROXY:-}" ] && run_args+=(-e "HTTP_PROXY=$HTTP_PROXY")
[ -n "${HTTPS_PROXY:-}" ] && run_args+=(-e "HTTPS_PROXY=$HTTPS_PROXY")
[ -n "${NO_PROXY:-}" ] && run_args+=(-e "NO_PROXY=$NO_PROXY")
# point at an Ollama container by IP, e.g. OLLAMA_BASE_URL=http://172.17.0.3:11434/v1,
# or set OLLAMA_CONTAINER=<name> above to resolve its IP automatically
[ -n "${OLLAMA_BASE_URL:-}" ] && run_args+=(-e "OLLAMA_BASE_URL=$OLLAMA_BASE_URL")
[ -n "${OLLAMA_MODELS:-}" ] && run_args+=(-e "OLLAMA_MODELS=$OLLAMA_MODELS")
[ -n "${OLLAMA_API_KEY:-}" ] && run_args+=(-e "OLLAMA_API_KEY=$OLLAMA_API_KEY")
# join an existing user-defined network (only needed for name-based DNS, not IP)
[ -n "${DOCKER_NETWORK:-}" ] && run_args+=(--network "$DOCKER_NETWORK")
# set DEBUG=1 for bash tracing plus network/settings.yaml dumps in the log
[ -n "${DEBUG:-}" ] && run_args+=(-e "DEBUG=$DEBUG")

log "Starting container $CONTAINER_NAME"
docker run "${run_args[@]}" "$IMAGE_NAME"

# 7. dsh prints a one-time per-process auth token; grab it and rewrite the URL
#    with the externally reachable $HOST_PORT (the token itself stays valid).
log "Waiting for the dsh web auth token"
token=""
for _ in $(seq 1 30); do
  token="$(docker logs "$CONTAINER_NAME" 2>&1 | sed -n 's/.*[?&]token=\([^ &]*\).*/\1/p' | tail -n1)"
  [ -n "$token" ] && break
  sleep 1
done

if [ -n "$token" ]; then
  log "Done. Web UI: http://$PUBLIC_HOST:$HOST_PORT/?token=$token  (logs: docker logs -f $CONTAINER_NAME)"
else
  log "Done, but no auth token seen yet. Web UI: http://$PUBLIC_HOST:$HOST_PORT  (check: docker logs -f $CONTAINER_NAME)"
fi
