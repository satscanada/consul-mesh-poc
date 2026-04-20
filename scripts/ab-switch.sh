#!/usr/bin/env bash
# ab-switch.sh
#
# Enables or disables the A/B routing demo for api-server.
# This script does not build Docker images. It assumes the cluster is already
# running images that include the A/B demo code:
#   - api-server:latest with APP_VARIANT support
#   - ui-app:latest forwarding X-Api-Variant and sending X-User-Group
#
# If your cluster is still on older images, rebuild/redeploy first:
#   ./scripts/deploy-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-default}"
ACTION="${1:-enable}"

BASE_ROUTER="${REPO_ROOT}/consul/servicerouter.yaml"
BASE_RESOLVER="${REPO_ROOT}/consul/serviceresolver.yaml"
AB_ROUTER="${REPO_ROOT}/consul/servicerouter-ab.yaml"
AB_RESOLVER="${REPO_ROOT}/consul/serviceresolver-ab.yaml"
VARIANT_B_DEPLOY="${REPO_ROOT}/api-server/k8s/deployment-variant-b.yaml"
BLUE_GREEN_V2_DEPLOY="${REPO_ROOT}/api-server/k8s/deployment-v2.yaml"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/ab-switch.sh enable
  ./scripts/ab-switch.sh disable
  ./scripts/ab-switch.sh status

Commands:
  enable   Apply the variant-b deployment and A/B routing config.
  disable  Restore the default stable router/resolver and remove variant-b.
  status   Show the current router, resolver, and api-server pods.

Notes:
  - No docker build happens here.
  - variant-a and variant-b use the same api-server:latest image; the visible
    difference comes from APP_VARIANT env and Consul subset routing.
  - enable automatically removes leftover blue-green v2 deployment state so
    A/B routing does not compete with the old demo.
EOF
}

cleanup_blue_green_state() {
  if kubectl get deployment api-server-v2 -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Detected leftover blue-green deployment (api-server-v2)."
    echo "Removing it before enabling A/B routing..."
    kubectl delete -f "${BLUE_GREEN_V2_DEPLOY}" --ignore-not-found
    kubectl wait --for=delete pod -l app=api-server,version=v2 -n "${NAMESPACE}" --timeout=90s >/dev/null 2>&1 || true
  fi
}

show_status() {
  echo "ServiceRouter subset targets:"
  kubectl get servicerouter api-server -n "${NAMESPACE}" \
    -o jsonpath='{range .spec.routes[*]}- {.destination.serviceSubset}{"\n"}{end}'
  echo
  echo "ServiceResolver default subset:"
  kubectl get serviceresolver api-server -n "${NAMESPACE}" \
    -o jsonpath='{.spec.defaultSubset}{"\n"}'
  echo
  echo "api-server pods:"
  kubectl get pods -n "${NAMESPACE}" -l app=api-server \
    -o custom-columns='NAME:.metadata.name,VERSION:.metadata.labels.version,VARIANT:.metadata.labels.variant,READY:.status.containerStatuses[0].ready,STATUS:.status.phase'
}

case "${ACTION}" in
  enable)
    cleanup_blue_green_state
    echo "Applying api-server variant-b deployment..."
    kubectl apply -f "${VARIANT_B_DEPLOY}"
    echo "Applying A/B ServiceResolver and ServiceRouter..."
    kubectl apply -f "${AB_RESOLVER}"
    kubectl apply -f "${AB_ROUTER}"
    echo
    echo "A/B routing is enabled."
    echo "Requests with X-User-Group: beta will route to variant-b."
    echo "No image build was performed; this only updates deployment + Consul config."
    show_status
    ;;
  disable)
    echo "Restoring baseline ServiceResolver and ServiceRouter..."
    kubectl apply -f "${BASE_RESOLVER}"
    kubectl apply -f "${BASE_ROUTER}"
    echo "Removing api-server variant-b deployment..."
    kubectl delete -f "${VARIANT_B_DEPLOY}" --ignore-not-found
    echo
    echo "A/B routing is disabled."
    show_status
    ;;
  status)
    show_status
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: ${ACTION}" >&2
    usage
    exit 1
    ;;
esac
