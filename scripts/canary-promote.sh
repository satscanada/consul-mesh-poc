#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-default}"
READY_TIMEOUT="${READY_TIMEOUT:-120s}"
SKIP_BUILD=false
TARGET_ONLY=""

CANARY_ROUTER="${REPO_ROOT}/consul/servicerouter-canary.yaml"
CANARY_RESOLVER="${REPO_ROOT}/consul/serviceresolver-canary.yaml"
CANARY_SPLITTER="${REPO_ROOT}/consul/servicesplitter-canary.yaml"
V2_DEPLOY="${REPO_ROOT}/api-server/k8s/deployment-v2.yaml"
VARIANT_B_DEPLOY="${REPO_ROOT}/api-server/k8s/deployment-variant-b.yaml"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/canary-promote.sh
  ./scripts/canary-promote.sh 50
  ./scripts/canary-promote.sh --skip-build

Behavior:
  - default flow confirms 10 -> 25 -> 50 -> 75 -> 100% traffic to v2
  - passing a percentage applies only that canary stage
  - removes leftover A/B variant-b deployment before enabling canary
  - recreates the v2 deployment so old blue-green leftovers do not carry over
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required." >&2; exit 1; }
}

apply_weight() {
  local v2_weight="$1"
  local v1_weight=$((100 - v2_weight))
  echo "Applying canary split: v1=${v1_weight}% | v2=${v2_weight}%"
  kubectl patch servicesplitter api-server -n "${NAMESPACE}" --type='merge' -p \
    "{\"spec\":{\"splits\":[{\"weight\":${v1_weight},\"serviceSubset\":\"v1\"},{\"weight\":${v2_weight},\"serviceSubset\":\"v2\"}]}}"
  echo "Current splitter:"
  kubectl get servicesplitter api-server -n "${NAMESPACE}" \
    -o jsonpath='{range .spec.splits[*]}- {.serviceSubset}: {.weight}{"%\n"}{end}'
}

cleanup_ab_state() {
  if kubectl get deployment api-server-variant-b -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Detected leftover A/B deployment (api-server-variant-b). Removing it first..."
    kubectl delete -f "${VARIANT_B_DEPLOY}" --ignore-not-found
    kubectl wait --for=delete pod -l app=api-server,variant=variant-b -n "${NAMESPACE}" --timeout=90s >/dev/null 2>&1 || true
  fi
}

cleanup_blue_green_state() {
  if kubectl get deployment api-server-v2 -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Detected existing blue-green v2 deployment. Recreating it for a clean canary start..."
    kubectl delete -f "${V2_DEPLOY}" --ignore-not-found
    kubectl wait --for=delete pod -l app=api-server,version=v2 -n "${NAMESPACE}" --timeout=90s >/dev/null 2>&1 || true
  fi
}

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    10|25|50|75|100) TARGET_ONLY="$arg" ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage; exit 1 ;;
  esac
done

require kubectl
if [[ "${SKIP_BUILD}" == false ]]; then
  require docker
fi

cleanup_ab_state
cleanup_blue_green_state

if [[ "${SKIP_BUILD}" == false ]]; then
  echo "Building api-server:v2 image..."
  docker build --build-arg APP_VERSION=v2 -t api-server:v2 "${REPO_ROOT}/api-server"
else
  echo "Skipping image build for api-server:v2"
fi

echo "Applying api-server v2 deployment..."
kubectl apply -f "${V2_DEPLOY}"
echo "Waiting for api-server-v2 rollout..."
kubectl rollout status deployment/api-server-v2 -n "${NAMESPACE}" --timeout="${READY_TIMEOUT}"

echo "Applying canary config entries..."
kubectl apply -f "${CANARY_RESOLVER}"
kubectl apply -f "${CANARY_ROUTER}"
kubectl apply -f "${CANARY_SPLITTER}"

if [[ -n "${TARGET_ONLY}" ]]; then
  apply_weight "${TARGET_ONLY}"
  exit 0
fi

for stage in 10 25 50 75 100; do
  printf "Promote canary to %s%% v2 traffic? [y/N] " "${stage}"
  read -r confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo "Stopping promotion at current stage."
    exit 0
  fi
  apply_weight "${stage}"
done
