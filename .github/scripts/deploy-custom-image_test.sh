#!/usr/bin/env bash
set -euo pipefail

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

cat > "$test_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_TEST_LOG"
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ "${args[$index]}" == bash && "${args[$((index + 1))]:-}" == -s ]]; then
    exec bash "${args[@]:$((index + 1))}"
  fi
done
cat >/dev/null
EOF

cat > "$test_dir/docker" <<'EOF'
#!/usr/bin/env bash
{
  printf 'DOCKER_CONFIG=%s' "${DOCKER_CONFIG:-}"
  printf ' %q' "$@"
  printf '\n'
} >> "$DOCKER_TEST_LOG"

if [[ "$1" == compose && " $* " == *" ps -q cli-proxy-api "* ]]; then
  echo "current-container"
elif [[ "$1" == inspect && "${!#}" == current-container ]]; then
  echo "harbor.example.test/cpa/cli-proxy-api:previous"
fi
EOF

cat > "$test_dir/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$test_dir/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$test_dir/ssh" "$test_dir/docker" "$test_dir/curl" "$test_dir/sleep"
mkdir "$test_dir/deploy"

export SSH_TEST_LOG="$test_dir/ssh.log"
export DOCKER_TEST_LOG="$test_dir/docker.log"
export PATH="$test_dir:$PATH"
export IMAGE_REF="harbor.example.test/cpa/cli-proxy-api:test"
export HARBOR_REGISTRY="harbor.example.test"
# The dollar sign is part of the Harbor robot account name.
# shellcheck disable=SC2016
robot_username='robot$project+deployer'
export HARBOR_USERNAME="$robot_username"
export HARBOR_PASSWORD="test-password"
export DEPLOY_HOST="127.0.0.1"
export DEPLOY_USER="deployer"
export DEPLOY_DIR="$test_dir/deploy"
export COMPOSE_FILE="compose.yml"
export HEALTH_URL="http://127.0.0.1:19988/"
export SSH_KEY_PATH="$test_dir/deploy-key"

if bash "$(dirname "$0")/deploy-custom-image.sh"; then
  echo "Expected the simulated health check to trigger rollback" >&2
  exit 1
fi

grep -F "$robot_username" "$SSH_TEST_LOG" >/dev/null
[[ "$(grep -c '^DOCKER_CONFIG=/tmp/cpa-harbor-manual-1 compose .* up ' "$DOCKER_TEST_LOG")" == 2 ]]
grep -F 'DOCKER_CONFIG=/tmp/cpa-harbor-manual-1 pull harbor.example.test/cpa/cli-proxy-api:test' "$DOCKER_TEST_LOG" >/dev/null

cat > "$test_dir/expected-override.yml" <<'EOF'
services:
  cli-proxy-api:
    image: harbor.example.test/cpa/cli-proxy-api:previous
    pull_policy: never
EOF
cmp "$test_dir/expected-override.yml" "$test_dir/deploy/.cpa-custom-image.override.yml"

echo "deploy-custom-image tests passed"
