#!/usr/bin/env bash
# deploy-all.sh — build Docker images, create the CockroachDB secret, and
#                 apply all Kubernetes + Consul manifests.
# Run from the repo root: ./scripts/deploy-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load .env if present (copy .env.example → .env and fill in values)
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  info "Loading ${ENV_FILE}"
  # Export each non-comment, non-blank line
  set -o allexport
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +o allexport
else
  warn ".env not found — falling back to environment variables / interactive prompts."
  warn "Copy .env.example to .env and fill in values to skip prompts."
fi

# ---------------------------------------------------------------------------
# Guard: must be on docker-desktop context
# ---------------------------------------------------------------------------
info "Verifying kubectl context"
CURRENT_CONTEXT=$(kubectl config current-context)
echo "    Active context: ${CURRENT_CONTEXT}"
EXPECTED_CONTEXT="${KUBE_CONTEXT:-docker-desktop}"
if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
  warn "Current context is '${CURRENT_CONTEXT}', not '${EXPECTED_CONTEXT}'."
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Build Docker images (uses Docker Desktop's built-in daemon)
# ---------------------------------------------------------------------------
API_SERVER_IMAGE="${API_SERVER_IMAGE:-api-server:latest}"
UI_APP_IMAGE="${UI_APP_IMAGE:-ui-app:latest}"

info "Building api-server image (${API_SERVER_IMAGE})"
docker build -t "${API_SERVER_IMAGE}" "${REPO_ROOT}/api-server"

info "Building ui-app image (${UI_APP_IMAGE})"
docker build -t "${UI_APP_IMAGE}" "${REPO_ROOT}/ui-app"

# ---------------------------------------------------------------------------
# CockroachDB CA certificate secret
# ---------------------------------------------------------------------------
info "Setting up cockroachdb-ca-cert secret"
DB_SSL_CERT_PATH="${DB_SSL_CERT_PATH:-${HOME}/.postgresql/root.crt}"
if [[ ! -f "${DB_SSL_CERT_PATH}" ]]; then
  die "CockroachDB CA cert not found at '${DB_SSL_CERT_PATH}'.
  Download it first:
    curl --create-dirs -o \$HOME/.postgresql/root.crt \\
      'https://cockroachlabs.cloud/clusters/<your-cluster-id>/cert'
  Then set DB_SSL_CERT_PATH in your .env if needed."
fi
kubectl create secret generic cockroachdb-ca-cert \
  --from-file=root.crt="${DB_SSL_CERT_PATH}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl get secret cockroachdb-ca-cert -n default > /dev/null || die "cockroachdb-ca-cert secret not found after creation"

# ---------------------------------------------------------------------------
# CockroachDB secret — read connection parts from env or prompt
# ---------------------------------------------------------------------------
info "Setting up cockroachdb-secret"

DB_HOST="${DB_HOST:-}"
DB_NAME="${DB_NAME:-defaultdb}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"

if [[ -z "${DB_HOST}" ]]; then
  read -r -p "CockroachDB host (e.g. free-tier.cockroachlabs.cloud): " DB_HOST
fi
if [[ -z "${DB_PASSWORD}" ]]; then
  read -r -s -p "CockroachDB password: " DB_PASSWORD
  echo
fi

kubectl create secret generic cockroachdb-secret \
  --from-literal=host="${DB_HOST}" \
  --from-literal=database="${DB_NAME}" \
  --from-literal=username="${DB_USER}" \
  --from-literal=password="${DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl get secret cockroachdb-secret -n default > /dev/null || die "cockroachdb-secret not found after creation"

# ---------------------------------------------------------------------------
# Consul mesh config entries (apply before workloads so intentions are ready)
# ---------------------------------------------------------------------------
info "Applying Consul mesh config entries"
kubectl apply -f "${REPO_ROOT}/consul/proxydefaults.yaml"
kubectl apply -f "${REPO_ROOT}/consul/serviceresolver.yaml"
kubectl apply -f "${REPO_ROOT}/consul/servicerouter.yaml"
kubectl apply -f "${REPO_ROOT}/consul/ingressgateway.yaml"

# ---------------------------------------------------------------------------
# api-server
# ---------------------------------------------------------------------------
info "Deploying api-server"
kubectl apply -f "${REPO_ROOT}/api-server/k8s/servicedefaults.yaml"
kubectl apply -f "${REPO_ROOT}/api-server/k8s/service.yaml"
kubectl apply -f "${REPO_ROOT}/api-server/k8s/deployment.yaml"

# ---------------------------------------------------------------------------
# ui-app (intentions first so deny-all is in place before pods start)
# ---------------------------------------------------------------------------
info "Deploying ui-app"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/servicedefaults.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/serviceintentions.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/service.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/deployment.yaml"

# ---------------------------------------------------------------------------
# Wait for rollouts
# ---------------------------------------------------------------------------
info "Waiting for api-server rollout"
kubectl rollout status deployment/api-server -n default --timeout=120s

info "Waiting for ui-app rollout"
kubectl rollout status deployment/ui-app -n default --timeout=120s

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo " Deployment complete!"
echo ""
echo " Consul UI:   kubectl port-forward svc/consul-ui -n consul 8500:80"
echo "              http://localhost:8500"
echo ""
echo " App UI:      http://localhost:8080   (via IngressGateway)"
echo "   or:        kubectl get svc ui-app  (NodePort)"
echo "================================================================"
