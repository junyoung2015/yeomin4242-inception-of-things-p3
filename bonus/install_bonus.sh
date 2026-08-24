#!/usr/bin/env bash
#
# Install the bonus on the same GCE L1/k3d cluster as P3. It intentionally
# does not start bonus/Vagrantfile: the bonus has one GitLab, in the gitlab
# namespace, and no public endpoint. All credentials are generated at runtime
# and removed or revoked before this script returns.

set -euo pipefail

REPO_URL="${REPO_URL:?Set REPO_URL to the public GitHub repository URL.}"
TARGET_REVISION="${TARGET_REVISION:?Set TARGET_REVISION, normally main.}"
K3D_CLUSTER="${K3D_CLUSTER:-iot-cluster}"
K3D_BIND_ADDRESS="${K3D_BIND_ADDRESS:-127.0.0.1}"
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8888}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
IMPORT_DIR="$RUNTIME_DIR/gitlab-import"
GITLAB_EXTERNAL_HOST="gitlab.gitlab.svc.cluster.local"
GITLAB_LOCAL_PORT="9999"
GITLAB_SERVICE_PORT="9999"
GITLAB_LOCAL_URL="http://$GITLAB_EXTERNAL_HOST:$GITLAB_LOCAL_PORT"
GITLAB_REPO_URL="$GITLAB_LOCAL_URL/root/iot-bonus.git"
HOSTS_MARKER="# iot-bonus-gitlab"
PORT_FORWARD_PID=""
ASKPASS_FILE=""
CURL_CONFIG_FILE=""
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
  [ -z "$CURL_CONFIG_FILE" ] || rm -f "$CURL_CONFIG_FILE"
  unset GITLAB_TOKEN GITLAB_HTTP_TOKEN GITLAB_HTTP_USERNAME
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for required_command in kubectl k3d git rsync curl jq openssl; do
  require_command "$required_command"
done

umask 077
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

REPO_URL="$REPO_URL" \
TARGET_REVISION="$TARGET_REVISION" \
K3D_CLUSTER="$K3D_CLUSTER" \
K3D_BIND_ADDRESS="$K3D_BIND_ADDRESS" \
K3D_HTTP_PORT="$K3D_HTTP_PORT" \
  "$REPO_ROOT/p3/install_and_setup.sh"

kubectl config use-context "k3d-$K3D_CLUSTER" >/dev/null
kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace dev-gitlab --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n gitlab get secret gitlab-bootstrap >/dev/null 2>&1; then
  gitlab_root_password="$(openssl rand -base64 48 | tr -d '\n')"
  printf '%s' "$gitlab_root_password" | \
    kubectl -n gitlab create secret generic gitlab-bootstrap \
      --from-file=root-password=/dev/stdin \
      --dry-run=client \
      -o yaml | \
    kubectl apply -f -
  unset gitlab_root_password
fi

kubectl apply -f "$SCRIPT_DIR/gitlab-service.yaml"
kubectl -n gitlab rollout status deployment/gitlab --timeout=1800s

start_gitlab_port_forward() {
  kubectl -n gitlab port-forward svc/gitlab "$GITLAB_LOCAL_PORT:$GITLAB_SERVICE_PORT" \
    >"$RUNTIME_DIR/gitlab-port-forward.log" 2>&1 &
  PORT_FORWARD_PID="$!"

  for attempt in {1..180}; do
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

ensure_gitlab_hosts_entry() {
  if grep -Fq "$GITLAB_EXTERNAL_HOST $HOSTS_MARKER" /etc/hosts; then
    return 0
  fi

  printf '127.0.0.1 %s %s\n' "$GITLAB_EXTERNAL_HOST" "$HOSTS_MARKER" | sudo tee -a /etc/hosts >/dev/null
}

create_runtime_pat() {
  local pat_result

  pat_result="$(kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner '
    require "securerandom"
    user = User.find_by_username("root")
    raise "root user is unavailable" unless user
    user.personal_access_tokens.where(name: "iot-bonus-import", revoked: false).find_each(&:revoke!)
    pat = user.personal_access_tokens.build(
      name: "iot-bonus-import",
      scopes: ["api", "write_repository"],
      expires_at: Date.current + 1
    )
    pat.set_token(SecureRandom.alphanumeric(20))
    pat.save!
    puts "#{pat.id}:#{pat.token}"
  ' | tail -n 1)"

  GITLAB_PAT_ID="$${pat_result%%:*}"
  GITLAB_TOKEN="$${pat_result#*:}"

  if ! [[ "$GITLAB_PAT_ID" =~ ^[0-9]+$ ]] || ! [[ "$GITLAB_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "GitLab did not return a valid runtime access token." >&2
    exit 1
  fi

  CURL_CONFIG_FILE="$RUNTIME_DIR/gitlab-curl.conf"
  printf 'header = "PRIVATE-TOKEN: %s"\n' "$GITLAB_TOKEN" > "$CURL_CONFIG_FILE"
  chmod 600 "$CURL_CONFIG_FILE"
}

gitlab_curl() {
  curl \
    --resolve "$GITLAB_EXTERNAL_HOST:$GITLAB_LOCAL_PORT:127.0.0.1" \
    --config "$CURL_CONFIG_FILE" \
    "$@"
}

ensure_gitlab_project() {
  if gitlab_curl -fsS \
    "$GITLAB_LOCAL_URL/api/v4/projects/root%2Fiot-bonus" >/dev/null; then
    return 0
  fi

  gitlab_curl -fsS -X POST \
    --data-urlencode "name=iot-bonus" \
    --data-urlencode "path=iot-bonus" \
    --data-urlencode "visibility=public" \
    "$GITLAB_LOCAL_URL/api/v4/projects" >/dev/null
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

copy_sanitized_project() {
  local item
  local -a rsync_excludes=(
    --exclude=.git
    --exclude=.vagrant
    --exclude=.runtime
    --exclude=.terraform
    --exclude=tmp
    --exclude=evidence
    --exclude='*.tfstate'
    --exclude='*.tfstate.*'
    --exclude='*.tfvars'
    --exclude='*.kubeconfig'
    --exclude=node-token
    --exclude=k3s.yaml
    --exclude=.DS_Store
  )

  rm -rf "$IMPORT_DIR"
  mkdir -p "$IMPORT_DIR"

  for item in .gitignore README.md dev p1 p2 p3 bonus iot-terraform scripts; do
    if [ -d "$REPO_ROOT/$item" ]; then
      rsync -a --delete "$${rsync_excludes[@]}" "$REPO_ROOT/$item/" "$IMPORT_DIR/$item/"
    elif [ -f "$REPO_ROOT/$item" ]; then
      rsync -a "$${rsync_excludes[@]}" "$REPO_ROOT/$item" "$IMPORT_DIR/"
    fi
  done
}

start_gitlab_port_forward
ensure_gitlab_hosts_entry
create_runtime_pat
ensure_gitlab_project
prepare_askpass
copy_sanitized_project

if git ls-remote "$GITLAB_REPO_URL" "refs/heads/main" | grep -q .; then
  echo "The local GitLab project already has a main branch; refusing to overwrite it." >&2
  exit 1
fi

git -C "$IMPORT_DIR" init -q
git -C "$IMPORT_DIR" checkout -q -b main
git -C "$IMPORT_DIR" config user.name "IoT Bonus Runtime Import"
git -C "$IMPORT_DIR" config user.email "iot-bonus@local.invalid"
git -C "$IMPORT_DIR" add .
git -C "$IMPORT_DIR" diff --cached --check
git -C "$IMPORT_DIR" commit -q -m "Import sanitized IoT project for local GitLab"
git -C "$IMPORT_DIR" remote add origin "$GITLAB_REPO_URL"
git -C "$IMPORT_DIR" push -q --set-upstream origin main
GITLAB_IMPORT_COMMIT="$(git -C "$IMPORT_DIR" rev-parse HEAD)"

kubectl apply -f "$SCRIPT_DIR/application_gitlab.yaml"

wait_for_application() {
  local app_name="$1"
  local expected_revision="$2"
  local namespace="$3"
  local sync_status health_status observed_revision

  for attempt in {1..180}; do
    sync_status="$(kubectl -n argocd get application "$app_name" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health_status="$(kubectl -n argocd get application "$app_name" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    observed_revision="$(kubectl -n argocd get application "$app_name" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"

    if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ] && [ "$observed_revision" = "$expected_revision" ]; then
      kubectl -n "$namespace" rollout status deployment/playground-deployment --timeout=300s
      return 0
    fi

    sleep 5
  done

  kubectl -n argocd get application "$app_name" -o yaml || true
  echo "Application $app_name did not automatically reach Synced/Healthy." >&2
  return 1
}

wait_for_application "playground-app-gitlab" "$GITLAB_IMPORT_COMMIT" "dev-gitlab"

echo "Bonus initial deployment is ready: GitLab is ClusterIP-only in namespace gitlab."
echo "The GitLab runtime password and import PAT were not printed and will not persist after this script."
