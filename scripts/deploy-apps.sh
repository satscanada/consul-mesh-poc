#!/usr/bin/env bash
# deploy-apps.sh
#
# Rebuild and redeploy only the application workloads:
#   - api-server
#   - ui-app
#
# This skips Consul installation, secrets creation, and base mesh setup.
# Use it when only app code has changed and the cluster is already bootstrapped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

EXPECTED_CONTEXT="${KUBE_CONTEXT:-docker-desktop}"
NAMESPACE="${NAMESPACE:-default}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"
API_SERVER_IMAGE="${API_SERVER_IMAGE:-api-server:latest}"
UI_APP_IMAGE="${UI_APP_IMAGE:-ui-app:latest}"

info "Verifying kubectl context"
CURRENT_CONTEXT=$(kubectl config current-context)
echo "    Active context: ${CURRENT_CONTEXT}"
if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
  warn "Current context is '${CURRENT_CONTEXT}', not '${EXPECTED_CONTEXT}'."
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

info "Building api-server image (${API_SERVER_IMAGE})"
docker build -t "${API_SERVER_IMAGE}" "${REPO_ROOT}/api-server"

info "Building ui-app image (${UI_APP_IMAGE})"
docker build -t "${UI_APP_IMAGE}" "${REPO_ROOT}/ui-app"

info "Reapplying app manifests"
kubectl apply -f "${REPO_ROOT}/api-server/k8s/servicedefaults.yaml"
kubectl apply -f "${REPO_ROOT}/api-server/k8s/service.yaml"
kubectl apply -f "${REPO_ROOT}/api-server/k8s/deployment.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/servicedefaults.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/serviceintentions.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/service.yaml"
kubectl apply -f "${REPO_ROOT}/ui-app/k8s/deployment.yaml"

if kubectl get deployment api-server-variant-b -n "${NAMESPACE}" >/dev/null 2>&1; then
  info "Refreshing active variant-b deployment"
  kubectl apply -f "${REPO_ROOT}/api-server/k8s/deployment-variant-b.yaml"
fi

info "Forcing rollout so rebuilt :latest images are picked up"
kubectl rollout restart deployment/api-server -n "${NAMESPACE}"
kubectl rollout restart deployment/ui-app -n "${NAMESPACE}"

if kubectl get deployment api-server-variant-b -n "${NAMESPACE}" >/dev/null 2>&1; then
  kubectl rollout restart deployment/api-server-variant-b -n "${NAMESPACE}"
fi

info "Waiting for api-server rollout"
kubectl rollout status deployment/api-server -n "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}"

info "Waiting for ui-app rollout"
kubectl rollout status deployment/ui-app -n "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}"

if kubectl get deployment api-server-variant-b -n "${NAMESPACE}" >/dev/null 2>&1; then
  info "Waiting for api-server-variant-b rollout"
  kubectl rollout status deployment/api-server-variant-b -n "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}"
fi

echo ""
echo "================================================================"
echo " App workloads redeployed!"
echo ""
echo " Refreshed:"
echo "   - api-server"
echo "   - ui-app"
if kubectl get deployment api-server-variant-b -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "   - api-server-variant-b"
fi
echo ""
echo " Use this after app-only code changes."
echo " Use ./scripts/deploy-all.sh for first-time setup or secret/mesh changes."
echo "================================================================"
