#!/usr/bin/env bash
# Stop and remove the server container. Weights and caches stay — ./run.sh brings it back fast.
set -euo pipefail
# the container runs as root — hand ./cache back to the host user before it goes
docker exec qwen-image-21-turbo chown -R "$(id -u):$(id -g)" /cache >/dev/null 2>&1 || true
# SIGTERM first: the server finishes the image in flight and releases the GPU cleanly; -t 30 = then SIGKILL
docker stop -t 30 qwen-image-21-turbo >/dev/null 2>&1 || true
docker rm -f qwen-image-21-turbo >/dev/null 2>&1 && echo "✓ stopped" || echo "· not running"
