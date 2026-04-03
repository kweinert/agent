#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# agent.sh
# Helper script for building and running your "agent" Docker container
# Put this in the same directory as your Dockerfile
# -----------------------------------------------------------------------------

# Get the directory of the actual script file (follows symlinks)
SCRIPT_DIR="$( cd -P "$( dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd )"

IMAGE_NAME="opencode-image"
CONTAINER_NAME="opencode-container"

# Default values — feel free to override via environment variables
PORT_MAPPING="2222:22"

usage() {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Commands:
  build          Build the Docker image
  run            Run (or restart) the container in detached mode
  stop           Stop and remove the running container
  logs           Show container logs (follow with -f)
  exec           Open an interactive shell inside the container
  help           Show this help message

Environment variables you can set:
  IMAGE_NAME       Docker image name (default: $IMAGE_NAME)
  CONTAINER_NAME   Container name     (default: $CONTAINER_NAME)
  PORT_MAPPING     Port mapping       (default: $PORT_MAPPING)
EOF
}

build() {
  echo "→ Changing to script directory: $SCRIPT_DIR"
  cd "$SCRIPT_DIR" || { echo "Error: cannot cd to $SCRIPT_DIR"; exit 1; }

  echo "→ Building Docker image: $IMAGE_NAME"
  docker build -t "$IMAGE_NAME" .

  echo "→ Build complete."
}

run() {
  echo "→ Starting container '$CONTAINER_NAME' ..."

  # Stop and remove if already running
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true

  # Try to start it
  if ! docker run -d \
    --name "$CONTAINER_NAME" \
    -p "$PORT_MAPPING" \
    --restart unless-stopped \
    -e GITHUB_TOKEN \
    "$IMAGE_NAME"; then
    echo "❌ Failed to create container" >&2
    exit 1
  fi

  # Wait and check
  echo "→ Waiting up to 20 seconds for container to be running ..."
  sleep 1
  local waited=0
  while [ $waited -lt 20 ]; do
    if docker inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | grep -q '^true$'; then
      echo "→ Container is running."
      echo "→ Connect with: ssh ubuntu@localhost -p 2222"
      echo "→ Or open shell: $0 exec"
      return 0
    fi

    sleep 1
    ((waited++))
  done

  # If we get here → failure
  echo "❌ Container failed to start (not running after 20 seconds)" >&2
  echo "   Logs:" >&2
  docker logs "$CONTAINER_NAME" >&2 2>/dev/null || echo "   (no logs available)" >&2
  exit 1
}

stop() {
  echo "→ Stopping and removing container '$CONTAINER_NAME' ..."
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "→ Done."
}

logs() {
  docker logs -f "$CONTAINER_NAME" 2>&1
}

exec_shell() {
  docker exec -it "$CONTAINER_NAME" bash
}

# -----------------------------------------------------------------------------
# Main command dispatch
# -----------------------------------------------------------------------------

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

case "$1" in
  build)
    build
    ;;
  run)
    run
    ;;
  stop)
    stop
    ;;
  logs)
    logs
    ;;
  exec)
    exec_shell
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo "Unknown command: $1"
    usage
    exit 1
    ;;
esac
