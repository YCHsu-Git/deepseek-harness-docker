#!/usr/bin/env bash
# Clone deepseek-ai/deepseek-harness, build a Docker image for it, and run the
# container. Run this script on a Linux host with Docker and git installed.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/deepseek-ai/deepseek-harness.git}"
CLONE_DIR="${CLONE_DIR:-$HOME/deepseek-harness}"
IMAGE_NAME="${IMAGE_NAME:-deepseek-harness:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-deepseek-harness}"
DSH_HOME_DIR="${DSH_HOME_DIR:-$HOME/.dsh}"
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

# 2. Drop in the Dockerfile/.dockerignore next to the checked-out sources.
cp "$SCRIPT_DIR/Dockerfile" "$CLONE_DIR/Dockerfile"
cp "$SCRIPT_DIR/.dockerignore" "$CLONE_DIR/.dockerignore"

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

# 6. Run the container. dsh's web app refuses --host 0.0.0.0, so the container
#    shares the host's network namespace and is reachable via the host's own
#    127.0.0.1:3080 (Linux only; --network host has no effect on Docker Desktop
#    for macOS/Windows).
run_args=(
  -d
  --name "$CONTAINER_NAME"
  --network host
  --restart unless-stopped
  -v "$DSH_HOME_DIR:/root/.dsh"
)
[ -n "${DEEPSEEK_API_KEY:-}" ] && run_args+=(-e "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY")

log "Starting container $CONTAINER_NAME"
docker run "${run_args[@]}" "$IMAGE_NAME"

log "Done. Web UI: http://127.0.0.1:3080  (logs: docker logs -f $CONTAINER_NAME)"
