#!/usr/bin/env bash
# teardown.sh — remove application workloads and Consul config entries.
#               Consul itself (the Helm release) is intentionally left in place.
# Run from the repo root: ./scripts/teardown.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Guard
# ---------------------------------------------------------------------------
info "Verifying kubectl context"
CURRENT_CONTEXT=$(kubectl config current-context)
echo "    Active context: ${CURRENT_CONTEXT}"
if [[ "${CURRENT_CONTEXT}" != "docker-desktop" ]]; then
  echo "WARNING: Current context is '${CURRENT_CONTEXT}', not 'docker-desktop'."
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Remove application workloads (ignore "not found" errors)
# ---------------------------------------------------------------------------
info "Removing ui-app"
kubectl delete -f "${REPO_ROOT}/ui-app/k8s/deployment.yaml"      --ignore-not-found
kubectl delete -f "${REPO_ROOT}/ui-app/k8s/service.yaml"         --ignore-not-found
kubectl delete -f "${REPO_ROOT}/ui-app/k8s/serviceintentions.yaml" --ignore-not-found

info "Removing api-server"
kubectl delete -f "${REPO_ROOT}/api-server/k8s/deployment.yaml"      --ignore-not-found
kubectl delete -f "${REPO_ROOT}/api-server/k8s/service.yaml"         --ignore-not-found
kubectl delete -f "${REPO_ROOT}/api-server/k8s/servicedefaults.yaml" --ignore-not-found

# ---------------------------------------------------------------------------
# Remove Consul mesh config entries
# ---------------------------------------------------------------------------
info "Removing Consul mesh config entries"
kubectl delete -f "${REPO_ROOT}/consul/ingressgateway.yaml"   --ignore-not-found
kubectl delete -f "${REPO_ROOT}/consul/servicerouter.yaml"    --ignore-not-found
kubectl delete -f "${REPO_ROOT}/consul/serviceresolver.yaml"  --ignore-not-found
kubectl delete -f "${REPO_ROOT}/consul/proxydefaults.yaml"    --ignore-not-found

# ---------------------------------------------------------------------------
# Remove the CockroachDB secret
# ---------------------------------------------------------------------------
info "Removing cockroachdb-secret"
kubectl delete secret cockroachdb-secret --ignore-not-found

echo ""
echo "================================================================"
echo " Teardown complete."
echo " Consul Helm release is still installed."
echo " To remove Consul: helm uninstall consul -n consul"
echo "================================================================"
