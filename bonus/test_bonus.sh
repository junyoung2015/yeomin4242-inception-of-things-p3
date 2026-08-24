#!/usr/bin/env bash
#
# Bonus proof: change the real deployment manifest in the local GitLab
# repository, commit, push, and wait for Argo CD's automated policy. This
# script never invokes a manual Argo sync and never writes a token into a Git
# remote URL, shell history, source file, or log.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
BONUS_GIT_REPO_DIR="${BONUS_GIT_REPO_DIR:-$RUNTIME_DIR/gitlab-import}"
TARGET_REVISION="${TARGET_REVISION:-main}"
FROM_IMAGE="${FROM_IMAGE:-wil42/playground:v1}"
TO_IMAGE="${TO_IMAGE:-wil42/playground:v2}"
GITLAB_EXTERNAL_HOST="gitlab.gitlab.svc.cluster.local"
GITLAB_LOCAL_PORT="9999"
GITLAB_SERVICE_PORT="9999"
GITLAB_LOCAL_URL="http://$GITLAB_EXTERNAL_HOST:$GITLAB_LOCAL_PORT"
GITLAB_REPO_URL="$GITLAB_LOCAL_URL/root/iot-bonus.git"
PORT_FORWARD_PID=""
ASKPASS_FILE=""
GITLAB_TOKEN=""
GITLAB_PAT_ID=""

cleanup() {
  if [ -n "$PORT_FORWARD_PID" ]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi

  if [ -n "$GITLAB_PAT_ID" ]; then
    kubectl -n gitlab exec deploy/gitlab -- \
      gitlab-rails runner "PersonalAccessToken.find_by(id: $GITLAB_PAT_ID)&.revoke!" \
      >/dev/null 2>&1 || true
  fi

  [ -z "$ASKPASS_FILE" ] || rm -f "$ASKPASS_FILE"
  unset GITLAB_TOKEN GITLAB_HTTP_TOKEN GITLAB_HTTP_USERNAME
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for required_command in kubectl git curl openssl; do
  require_command "$required_command"
done

if [ ! -d "$BONUS_GIT_REPO_DIR/.git" ]; then
  echo "Run install_bonus.sh first; no local GitLab import clone exists." >&2
  exit 1
fi

for required_namespace in argocd dev gitlab dev-gitlab; do
  kubectl get namespace "$required_namespace" >/dev/null
done

kubectl -n gitlab rollout status deployment/gitlab --timeout=1800s
kubectl -n dev rollout status deployment/playground-deployment --timeout=300s
kubectl -n dev-gitlab rollout status deployment/playground-deployment --timeout=300s

start_gitlab_port_forward() {
  kubectl -n gitlab port-forward svc/gitlab "$GITLAB_LOCAL_PORT:$GITLAB_SERVICE_PORT" \
    >"$RUNTIME_DIR/gitlab-test-port-forward.log" 2>&1 &
  PORT_FORWARD_PID="$!"

  for attempt in {1..120}; do
    http_code="$(curl --resolve "$GITLAB_EXTERNAL_HOST:$GITLAB_LOCAL_PORT:127.0.0.1" \
      -s -o /dev/null -w '%{http_code}' "$GITLAB_LOCAL_URL/users/sign_in" || true)"
    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
      return 0
    fi
    sleep 5
  done

  echo "GitLab did not become reachable through the temporary localhost tunnel." >&2
  return 1
}

create_test_pat() {
  local pat_result

  pat_result="$(kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner '
    require "securerandom"
    user = User.find_by_username("root")
    raise "root user is unavailable" unless user
    user.personal_access_tokens.where(name: "iot-bonus-test", revoked: false).find_each(&:revoke!)
    pat = user.personal_access_tokens.build(
      name: "iot-bonus-test",
      scopes: ["write_repository"],
      expires_at: Date.current + 1
    )
    pat.set_token(SecureRandom.alphanumeric(20))
    pat.save!
    puts "#{pat.id}:#{pat.token}"
  ' | tail -n 1)"

  GITLAB_PAT_ID="$${pat_result%%:*}"
  GITLAB_TOKEN="$${pat_result#*:}"

  if ! [[ "$GITLAB_PAT_ID" =~ ^[0-9]+$ ]] || ! [[ "$GITLAB_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "GitLab did not return a valid runtime push token." >&2
    exit 1
  fi
}

prepare_askpass() {
  ASKPASS_FILE="$(mktemp "$RUNTIME_DIR/git-askpass.XXXXXX")"
  cat > "$ASKPASS_FILE" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  *Username*) printf '%s\n' "$GITLAB_HTTP_USERNAME" ;;
  *Password*) printf '%s\n' "$GITLAB_HTTP_TOKEN" ;;
  *) exit 1 ;;
esac
EOF
  chmod 700 "$ASKPASS_FILE"
  export GIT_ASKPASS="$ASKPASS_FILE"
  export GIT_TERMINAL_PROMPT=0
  export GITLAB_HTTP_USERNAME="oauth2"
  export GITLAB_HTTP_TOKEN="$GITLAB_TOKEN"
}

wait_for_automatic_gitlab_sync() {
  local expected_revision="$1"
  local sync_status health_status observed_revision running_image

  for attempt in {1..180}; do
    sync_status="$(kubectl -n argocd get application playground-app-gitlab -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health_status="$(kubectl -n argocd get application playground-app-gitlab -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    observed_revision="$(kubectl -n argocd get application playground-app-gitlab -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    running_image="$(kubectl -n dev-gitlab get deployment playground-deployment -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ] && \
       [ "$observed_revision" = "$expected_revision" ] && [ "$running_image" = "$TO_IMAGE" ]; then
      return 0
    fi

    sleep 5
  done

  kubectl -n argocd get application playground-app-gitlab -o yaml || true
  kubectl -n dev-gitlab get deployment playground-deployment -o wide || true
  echo "GitLab Application did not automatically reconcile the pushed v2 commit." >&2
  return 1
}

check_http() {
  local host_header="$1"

  for attempt in {1..24}; do
    if curl --connect-timeout 3 -fsS -H "Host: $host_header" http://127.0.0.1:8888/ >/dev/null; then
      return 0
    fi
    sleep 5
  done

  echo "No HTTP 200 response for $host_header through the local-only k3d ingress." >&2
  return 1
}

for app_name in playground-app playground-app-gitlab; do
  sync_status="$(kubectl -n argocd get application "$app_name" -o jsonpath='{.status.sync.status}')"
  health_status="$(kubectl -n argocd get application "$app_name" -o jsonpath='{.status.health.status}')"
  if [ "$sync_status" != "Synced" ] || [ "$health_status" != "Healthy" ]; then
    echo "$app_name is not initially Synced and Healthy." >&2
    exit 1
  fi
done

start_gitlab_port_forward
create_test_pat
prepare_askpass

if git -C "$BONUS_GIT_REPO_DIR" remote get-url origin | grep -Eq '://[^/[:space:]]+@'; then
  echo "Refusing a Git remote URL that embeds credentials." >&2
  exit 1
fi

git -C "$BONUS_GIT_REPO_DIR" fetch origin "$TARGET_REVISION"
git -C "$BONUS_GIT_REPO_DIR" switch "$TARGET_REVISION"
git -C "$BONUS_GIT_REPO_DIR" pull --ff-only origin "$TARGET_REVISION"

if ! git -C "$BONUS_GIT_REPO_DIR" diff --quiet || ! git -C "$BONUS_GIT_REPO_DIR" diff --cached --quiet; then
  echo "Refusing to change a dirty local GitLab import clone." >&2
  exit 1
fi

MANIFEST="$BONUS_GIT_REPO_DIR/dev/deployment.yaml"
if ! grep -Fq "$FROM_IMAGE" "$MANIFEST"; then
  echo "Expected source image $FROM_IMAGE is not present in $MANIFEST." >&2
  exit 1
fi

sed -i "s|$FROM_IMAGE|$TO_IMAGE|g" "$MANIFEST"
git -C "$BONUS_GIT_REPO_DIR" add dev/deployment.yaml
git -C "$BONUS_GIT_REPO_DIR" commit -m "Verify local GitLab automatic v2 rollout"
git -C "$BONUS_GIT_REPO_DIR" push origin "$TARGET_REVISION"
EXPECTED_REVISION="$(git -C "$BONUS_GIT_REPO_DIR" rev-parse HEAD)"

wait_for_automatic_gitlab_sync "$EXPECTED_REVISION"
check_http "playground.local"
check_http "playground-gitlab.local"

echo "Bonus automatic GitLab GitOps proof passed at commit $EXPECTED_REVISION."
