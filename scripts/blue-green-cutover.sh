#!/usr/bin/env bash
# =============================================================================
# blue-green-cutover.sh
#
# Full end-to-end blue-green cutover: builds the target image, applies the
# Consul config entries and Kubernetes deployment, waits for the target pods
# to be ready, then patches the ServiceRouter / ServiceResolver to shift
# 100% of traffic to the chosen version.
#
# Usage:
#   ./scripts/blue-green-cutover.sh v1            # cut over to v1 (blue)
#   ./scripts/blue-green-cutover.sh v2            # cut over to v2 (green)
#   ./scripts/blue-green-cutover.sh               # auto-toggle (flips current)
#   ./scripts/blue-green-cutover.sh v2 --skip-build   # skip docker build step
#
# Environment overrides:
#   NAMESPACE=default   CONSUL_NAMESPACE=consul
#   READY_TIMEOUT=120s  (kubectl rollout wait timeout)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-default}"
SERVICE="api-server"
READY_TIMEOUT="${READY_TIMEOUT:-120s}"
SKIP_BUILD=false

# ── parse args ────────────────────────────────────────────────────────────────
TARGET=""
for arg in "$@"; do
  case "$arg" in
    v1|v2)       TARGET="$arg" ;;
    --skip-build) SKIP_BUILD=true ;;
    *) printf 'Unknown argument: %s\n' "$arg"; exit 1 ;;
  esac
done

# ── helpers ──────────────────────────────────────────────────────────────────
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;34m──\033[0m %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { red "ERROR: '$1' is required but not found."; exit 1; }
}

require kubectl
require docker

# ── auto-toggle if no target given ───────────────────────────────────────────
if [[ -z "$TARGET" ]]; then
  CURRENT=$(kubectl get servicerouter "$SERVICE" -n "$NAMESPACE" \
    -o jsonpath='{.spec.routes[0].destination.serviceSubset}' 2>/dev/null || echo "v1")
  TARGET=$([[ "$CURRENT" == "v1" ]] && echo "v2" || echo "v1")
fi

if [[ "$TARGET" != "v1" && "$TARGET" != "v2" ]]; then
  red "ERROR: target must be 'v1' or 'v2', got: $TARGET"
  exit 1
fi

# ── derived values ────────────────────────────────────────────────────────────
IMAGE="api-server:${TARGET}"
if [[ "$TARGET" == "v1" ]]; then
  DEPLOYMENT_MANIFEST="${REPO_ROOT}/api-server/k8s/deployment.yaml"
  DEPLOY_NAME="api-server"
else
  DEPLOYMENT_MANIFEST="${REPO_ROOT}/api-server/k8s/deployment-v2.yaml"
  DEPLOY_NAME="api-server-v2"
fi
RESOLVER_MANIFEST="${REPO_ROOT}/consul/serviceresolver-blue-green.yaml"
ROUTER_MANIFEST="${REPO_ROOT}/consul/servicerouter-blue-green.yaml"

# ── header ────────────────────────────────────────────────────────────────────
bold "=== Blue-Green Cutover: api-server ==="
if [[ "$TARGET" == "v1" ]]; then
  blue  "  Target  : v1 (BLUE — stable)"
else
  green "  Target  : v2 (GREEN — new)"
fi
echo   "  Image   : ${IMAGE}"
echo   "  Deploy  : ${DEPLOY_NAME}"
echo   "  Timeout : ${READY_TIMEOUT}"
[[ "$SKIP_BUILD" == true ]] && echo "  Build   : skipped (--skip-build)"

# ── Step 1: build Docker image ────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
  step "Building Docker image ${IMAGE}"
  docker build \
    --build-arg APP_VERSION="${TARGET}" \
    -t "${IMAGE}" \
    "${REPO_ROOT}/api-server"
  echo "  ✔ Image ${IMAGE} built"
else
  echo ""
  echo "  Skipping build — using existing image ${IMAGE}"
fi

# ── Step 2: apply Consul config entries (idempotent) ─────────────────────────
step "Applying Consul blue-green config entries"
kubectl apply -f "${RESOLVER_MANIFEST}"
kubectl apply -f "${ROUTER_MANIFEST}"
echo "  ✔ ServiceResolver and ServiceRouter applied"

# ── Step 3: apply target Kubernetes deployment ────────────────────────────────
step "Applying deployment: ${DEPLOY_NAME}"
kubectl apply -f "${DEPLOYMENT_MANIFEST}"
echo "  ✔ Deployment ${DEPLOY_NAME} applied"

# ── Step 4: wait for target deployment to be ready ───────────────────────────
step "Waiting for ${DEPLOY_NAME} to be ready (timeout: ${READY_TIMEOUT})"
kubectl rollout status deployment/"${DEPLOY_NAME}" \
  -n "${NAMESPACE}" \
  --timeout="${READY_TIMEOUT}"

# Confirm Consul sidecar is also injected (2/2 containers)
READY=$(kubectl get pods -n "${NAMESPACE}" \
  -l "app=${SERVICE}${TARGET:+,version=${TARGET}}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
echo "  Pod container ready states: ${READY:-unknown}"

# ── Step 5: patch ServiceRouter + ServiceResolver ────────────────────────────
step "Patching Consul routing → subset ${TARGET}"
kubectl patch servicerouter "$SERVICE" \
  -n "$NAMESPACE" \
  --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/routes/0/destination/serviceSubset\", \"value\": \"${TARGET}\"}]"

kubectl patch serviceresolver "$SERVICE" \
  -n "$NAMESPACE" \
  --type='merge' \
  -p="{\"spec\": {\"defaultSubset\": \"${TARGET}\"}}"

# ── Step 6: verify ────────────────────────────────────────────────────────────
step "Verifying"
ROUTER_SUBSET=$(kubectl get servicerouter "$SERVICE" -n "$NAMESPACE" \
  -o jsonpath='{.spec.routes[0].destination.serviceSubset}')
RESOLVER_DEFAULT=$(kubectl get serviceresolver "$SERVICE" -n "$NAMESPACE" \
  -o jsonpath='{.spec.defaultSubset}')

echo "  ServiceRouter   → serviceSubset  : ${ROUTER_SUBSET}"
echo "  ServiceResolver → defaultSubset  : ${RESOLVER_DEFAULT}"
echo ""
echo "  Pods:"
kubectl get pods -n "${NAMESPACE}" -l "app=${SERVICE}" \
  -o custom-columns="    NAME:.metadata.name,VERSION:.metadata.labels.version,READY:.status.containerStatuses[0].ready,STATUS:.status.phase"

echo ""
if [[ "$ROUTER_SUBSET" == "$TARGET" && "$RESOLVER_DEFAULT" == "$TARGET" ]]; then
  if [[ "$TARGET" == "v1" ]]; then
    blue  "✔ Cutover complete — 100% traffic → v1 (BLUE)"
  else
    green "✔ Cutover complete — 100% traffic → v2 (GREEN)"
  fi
  echo ""
  echo "  Refresh http://localhost:4000 to see the version badge update."
else
  red "WARNING: routing did not update as expected — check kubectl get servicerouter/serviceresolver"
  exit 1
fi
