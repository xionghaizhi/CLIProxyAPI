#!/usr/bin/env bash
set -euo pipefail

required=(
  IMAGE_REF REGISTRY_HOST REGISTRY_USERNAME REGISTRY_TOKEN
  DEPLOY_HOST DEPLOY_USER DEPLOY_DIR COMPOSE_FILE HEALTH_URL SSH_KEY_PATH
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'Missing required environment variable: %s\n' "$name" >&2
    exit 1
  fi
done

if [[ ! "$DEPLOY_HOST" =~ ^[A-Za-z0-9.:-]+$ || ! "$DEPLOY_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid deployment host or user" >&2
  exit 1
fi
if [[ ! "$DEPLOY_DIR" =~ ^/[A-Za-z0-9._/-]+$ || ! "$COMPOSE_FILE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid deployment directory or Compose filename" >&2
  exit 1
fi
if [[ ! "$IMAGE_REF" =~ ^[A-Za-z0-9._:/-]+$ || ! "$REGISTRY_HOST" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  echo "Invalid image reference or registry host" >&2
  exit 1
fi
if [[ ! "$REGISTRY_USERNAME" =~ ^[-A-Za-z0-9._@+\$]+$ || ! "$HEALTH_URL" =~ ^http://127\.0\.0\.1:[0-9]+/[A-Za-z0-9._/-]*$ ]]; then
  echo "Invalid registry username or health URL" >&2
  exit 1
fi

ssh_target="${DEPLOY_USER}@${DEPLOY_HOST}"
ssh_args=(-i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=yes)
remote_docker_config="/tmp/cpa-registry-${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}"

cleanup() {
  # Validated values are intentionally expanded before the remote shell runs.
  # shellcheck disable=SC2029
  ssh "${ssh_args[@]}" "$ssh_target" "rm -rf '$remote_docker_config'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Validated values are intentionally expanded before the remote shell runs.
# shellcheck disable=SC2029
ssh "${ssh_args[@]}" "$ssh_target" "install -d -m 700 '$remote_docker_config'"
# Validated values are intentionally expanded before the remote shell runs.
# shellcheck disable=SC2029
printf '%s' "$REGISTRY_TOKEN" | ssh "${ssh_args[@]}" "$ssh_target" \
  "DOCKER_CONFIG='$remote_docker_config' docker login '$REGISTRY_HOST' --username '$REGISTRY_USERNAME' --password-stdin"

ssh "${ssh_args[@]}" "$ssh_target" bash -s -- \
  "$DEPLOY_DIR" "$COMPOSE_FILE" "$IMAGE_REF" "$HEALTH_URL" "$remote_docker_config" <<'REMOTE'
set -euo pipefail

deploy_dir="$1"
compose_file="$2"
image_ref="$3"
health_url="$4"
docker_config="$5"
service="cli-proxy-api"
override_file=".cpa-custom-image.override.yml"

cd "$deploy_dir"
current_container="$(docker compose -f "$compose_file" ps -q "$service")"
if [[ -z "$current_container" ]]; then
  echo "Cannot find the current $service container" >&2
  exit 1
fi
previous_image="$(docker inspect --format '{{.Config.Image}}' "$current_container")"

write_override() {
  local selected_image="$1"
  cat > "$override_file" <<EOF
services:
  $service:
    image: $selected_image
    pull_policy: never
EOF
}

rollback() {
  echo "Rolling back to $previous_image" >&2
  write_override "$previous_image"
  DOCKER_CONFIG="$docker_config" docker compose -f "$compose_file" -f "$override_file" up -d --no-deps "$service"
}

DOCKER_CONFIG="$docker_config" docker pull "$image_ref"
write_override "$image_ref"
if ! DOCKER_CONFIG="$docker_config" docker compose -f "$compose_file" -f "$override_file" up -d --no-deps "$service"; then
  rollback
  exit 1
fi

healthy=false
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "$health_url" >/dev/null; then
    healthy=true
    break
  fi
  sleep 2
done

if [[ "$healthy" != true ]]; then
  echo "Health check failed" >&2
  rollback
  exit 1
fi

container_id="$(docker compose -f "$compose_file" -f "$override_file" ps -q "$service")"
docker inspect --format 'deployed_image={{.Config.Image}} status={{.State.Status}}' "$container_id"
REMOTE
