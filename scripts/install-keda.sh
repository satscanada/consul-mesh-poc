#!/usr/bin/env bash
# scripts/install-keda.sh
# -----------------------------------------------------------------------
# Installs KEDA (Kubernetes Event-driven Autoscaling) for consul-mesh-poc.
#
# Prerequisites:
#   - Step 13 observability stack installed (kube-prometheus-stack running)
#     Prometheus must be reachable at:
#     http://prometheus-operated.monitoring.svc:9090
#   - kubectl configured for the target cluster
#   - helm >= 3.x installed
#
# What this script does:
#   1. Adds the kedacore Helm repo
#   2. Installs KEDA into the 'keda' namespace
#   3. Waits for the KEDA operator and metrics adapter to be Ready
#   4. Verifies all required CRDs are registered
#   5. Prints a summary and next-step instructions
#
# Usage:
#   ./scripts/install-keda.sh
#   ./scripts/install-keda.sh --dry-run   # print what would be installed
# -----------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

KEDA_NAMESPACE="keda"
KEDA_CHART="kedacore/keda"
KEDA_RELEASE="keda"
KEDA_VERSION=""          # leave empty to install the latest stable release

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# -----------------------------------------------------------------------
# Colour helpers (same palette as install-observability.sh)
# -----------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# -----------------------------------------------------------------------
# Dry-run guard
# -----------------------------------------------------------------------
run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} $*"
  else
    "$@"
  fi
}

# -----------------------------------------------------------------------
# 0. Preflight — confirm Prometheus is reachable
# -----------------------------------------------------------------------
info "Checking prerequisites..."

if ! kubectl get namespace monitoring &>/dev/null; then
  error "Namespace 'monitoring' not found. Install the observability stack (Step 13) first:"
  error "  ./scripts/install-observability.sh"
  exit 1
fi

if ! kubectl get svc prometheus-operated -n monitoring &>/dev/null; then
  error "Service 'prometheus-operated' not found in namespace 'monitoring'."
  error "Ensure kube-prometheus-stack is installed and healthy before running this script."
  exit 1
fi

success "Prometheus service found in namespace 'monitoring'."

# -----------------------------------------------------------------------
# 1. Helm repo
# -----------------------------------------------------------------------
info "Adding / updating kedacore Helm repo..."
run helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
run helm repo update
success "Helm repo 'kedacore' is up to date."

# -----------------------------------------------------------------------
# 2. Create namespace
# -----------------------------------------------------------------------
info "Ensuring namespace '${KEDA_NAMESPACE}' exists..."
run kubectl create namespace "${KEDA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
success "Namespace '${KEDA_NAMESPACE}' ready."

# -----------------------------------------------------------------------
# 3. Install KEDA
# -----------------------------------------------------------------------
VERSION_FLAG=""
if [[ -n "${KEDA_VERSION}" ]]; then
  VERSION_FLAG="--version ${KEDA_VERSION}"
fi

if helm status "${KEDA_RELEASE}" -n "${KEDA_NAMESPACE}" &>/dev/null; then
  info "KEDA release '${KEDA_RELEASE}' already exists — upgrading..."
  run helm upgrade "${KEDA_RELEASE}" "${KEDA_CHART}" \
    --namespace "${KEDA_NAMESPACE}" \
    ${VERSION_FLAG} \
    --wait \
    --timeout 5m
  success "KEDA upgraded."
else
  info "Installing KEDA (release: ${KEDA_RELEASE}, namespace: ${KEDA_NAMESPACE})..."
  run helm install "${KEDA_RELEASE}" "${KEDA_CHART}" \
    --namespace "${KEDA_NAMESPACE}" \
    ${VERSION_FLAG} \
    --set watchNamespace="" \
    --set prometheus.metricServer.enabled=true \
    --set prometheus.operator.enabled=true \
    --wait \
    --timeout 5m
  success "KEDA installed."
fi

# -----------------------------------------------------------------------
# 4. Wait for KEDA pods to be Ready
# -----------------------------------------------------------------------
info "Waiting for KEDA pods to be Ready..."
run kubectl rollout status deployment/keda-operator          -n "${KEDA_NAMESPACE}" --timeout=3m
run kubectl rollout status deployment/keda-operator-metrics-apiserver -n "${KEDA_NAMESPACE}" --timeout=3m
success "KEDA pods are Ready."

# -----------------------------------------------------------------------
# 5. Verify required CRDs are registered
# -----------------------------------------------------------------------
info "Verifying KEDA CRDs..."

REQUIRED_CRDS=(
  "scaledobjects.keda.sh"
  "scaledjobs.keda.sh"
  "triggerauthentications.keda.sh"
  "clustertriggerauthentications.keda.sh"
)

ALL_OK=true
for crd in "${REQUIRED_CRDS[@]}"; do
  if kubectl get crd "${crd}" &>/dev/null; then
    success "CRD registered: ${crd}"
  else
    error  "CRD MISSING:    ${crd}"
    ALL_OK=false
  fi
done

if [[ "$ALL_OK" != true ]]; then
  error "One or more CRDs are missing. Check 'helm status keda -n keda' for details."
  exit 1
fi

# -----------------------------------------------------------------------
# 6. Summary
# -----------------------------------------------------------------------
echo ""
echo -e "${GREEN}=========================================================${NC}"
echo -e "${GREEN}  KEDA installation complete${NC}"
echo -e "${GREEN}=========================================================${NC}"
echo ""

info "KEDA pods:"
kubectl get pods -n "${KEDA_NAMESPACE}"

echo ""
info "ScaledObjects across all namespaces (should be empty until Step 14.3):"
kubectl get scaledobject -A 2>/dev/null || warn "No ScaledObjects found yet (expected at this stage)."

echo ""
info "Installed KEDA version:"
helm list -n "${KEDA_NAMESPACE}" --filter "^${KEDA_RELEASE}$" \
  --output table 2>/dev/null | tail -n +2 | awk '{print "  Chart:", $9, "  App:", $10}'

echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Apply TriggerAuthentication:"
echo "       kubectl apply -f keda/triggerauthentication.yaml"
echo ""
echo "  2. Apply ScaledObjects:"
echo "       kubectl apply -f keda/scaledobject-api-server.yaml"
echo "       kubectl apply -f keda/scaledobject-api-server-v2.yaml"
echo ""
echo "  3. Verify scaling is active:"
echo "       kubectl describe scaledobject api-server"
echo "       kubectl get hpa -n default"
echo ""
echo "  4. Run a load test to trigger scale-up:"
echo "       ./scripts/generate-api-traffic.sh --rps 100 --duration 120"
echo ""
echo "  See docs/observability/KEDA_AUTOSCALING.md for the full walkthrough."
