#!/usr/bin/env bash
# install-consul.sh — installs Consul OSS on Docker Desktop Kubernetes
# Run from the repo root: ./scripts/install-consul.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_FILE="${REPO_ROOT}/consul/helm-values.yaml"
CONSUL_NAMESPACE="consul"
RELEASE_NAME="consul"
CHART="hashicorp/consul"

echo "==> Verifying kubectl context"
CURRENT_CONTEXT=$(kubectl config current-context)
echo "    Active context: ${CURRENT_CONTEXT}"
if [[ "${CURRENT_CONTEXT}" != "docker-desktop" ]]; then
  echo "WARNING: current context is '${CURRENT_CONTEXT}', not 'docker-desktop'."
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo "==> Adding HashiCorp Helm repository"
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update

echo "==> Creating namespace '${CONSUL_NAMESPACE}' (idempotent)"
kubectl create namespace "${CONSUL_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing / upgrading Consul via Helm"
helm upgrade --install "${RELEASE_NAME}" "${CHART}" \
  --namespace "${CONSUL_NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --timeout 10m \
  --wait

echo ""
echo "==> Consul installation complete. Pod status:"
kubectl get pods -n "${CONSUL_NAMESPACE}"

echo ""
echo "================================================================"
echo " Consul UI — port-forward command:"
echo ""
echo "   kubectl port-forward svc/consul-ui -n consul 8500:80"
echo ""
echo "   Then open: http://localhost:8500"
echo "================================================================"
