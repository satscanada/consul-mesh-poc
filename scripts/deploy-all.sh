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
# Guard: must be on docker-desktop context
# ---------------------------------------------------------------------------
info "Verifying kubectl context"
CURRENT_CONTEXT=$(kubectl config current-context)
echo "    Active context: ${CURRENT_CONTEXT}"
if [[ "${CURRENT_CONTEXT}" != "docker-desktop" ]]; then
  warn "Current context is '${CURRENT_CONTEXT}', not 'docker-desktop'."
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Build Docker images (uses Docker Desktop's built-in daemon)
# ---------------------------------------------------------------------------
info "Building api-server image"
docker build -t api-server:latest "${REPO_ROOT}/api-server"

info "Building ui-app image"
docker build -t ui-app:latest "${REPO_ROOT}/ui-app"

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
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/serviceintentions.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/service.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/deployment.yaml"

# ---------------------------------------------------------------------------
# Wait for rollouts
# ---------------------------------------------------------------------------
info "Waiting for api-server rollout"
kubectl rollout status deployment/api-server --timeout=120s

info "Waiting for ui-app rollout"
kubectl rollout status deployment/ui-app --timeout=120s

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
