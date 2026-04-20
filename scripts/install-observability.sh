#!/usr/bin/env bash
# scripts/install-observability.sh
# -----------------------------------------------------------------------
# Installs the full observability stack for consul-mesh-poc:
#   1. kube-prometheus-stack  (Prometheus + Grafana)
#   2. Jaeger all-in-one      (distributed tracing)
#   3. Consul custom dashboard ConfigMap
#   4. ProxyDefaults with tracing enabled (replaces consul/proxydefaults.yaml)
#
# Run AFTER the base consul-mesh-poc is already deployed.
# See observability/quickstart.md for step-by-step instructions.
# -----------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

PROM_NAMESPACE="monitoring"
JAEGER_NAMESPACE="default"   # keep with app pods so Envoy can reach it easily

# Tear down the failed install
# helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
# kubectl delete namespace monitoring --ignore-not-found
# kubectl delete configmap consul-mesh-poc-dashboard -n monitoring --ignore-not-found

# -----------------------------------------------------------------------
# Colour helpers
# -----------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# -----------------------------------------------------------------------
# 1. Helm repos
# -----------------------------------------------------------------------
info "Adding / updating Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add jaegertracing        https://jaegertracing.github.io/helm-charts        2>/dev/null || true
helm repo update
success "Helm repos up to date."

# -----------------------------------------------------------------------
# 2. Grafana custom dashboard ConfigMap
#    Must exist BEFORE helm install --wait so Grafana can mount it at
#    startup (dashboardsConfigMaps references it by name).
# -----------------------------------------------------------------------
info "Creating Grafana dashboard ConfigMap..."
kubectl create namespace "${PROM_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap consul-mesh-poc-dashboard \
  --from-file=consul-mesh-poc.json="${ROOT_DIR}/observability/grafana-dashboard-consul.json" \
  --namespace "${PROM_NAMESPACE}" \
  --dry-run=client -o yaml \
| kubectl apply -f -

# The chart already mounts this ConfigMap via `dashboardsConfigMaps`.
# Removing any legacy sidecar label avoids duplicate provisioning of the same UID.
kubectl label configmap consul-mesh-poc-dashboard \
  --namespace "${PROM_NAMESPACE}" \
  grafana_dashboard- >/dev/null 2>&1 || true

success "Grafana dashboard ConfigMap applied."

# Force Grafana to pick up dashboard ConfigMap changes on repeat runs.
if kubectl get deployment kube-prometheus-stack-grafana -n "${PROM_NAMESPACE}" >/dev/null 2>&1; then
  info "Refreshing Grafana deployment so updated dashboards are reloaded..."
  kubectl rollout restart deployment/kube-prometheus-stack-grafana -n "${PROM_NAMESPACE}"
fi

# -----------------------------------------------------------------------
# 3. kube-prometheus-stack
# -----------------------------------------------------------------------
info "Installing kube-prometheus-stack into namespace '${PROM_NAMESPACE}'..."

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "${PROM_NAMESPACE}" \
  --values "${ROOT_DIR}/observability/prometheus-values.yaml" \
  --wait \
  --timeout 5m

success "kube-prometheus-stack installed."

# -----------------------------------------------------------------------
# 4. Jaeger all-in-one
# -----------------------------------------------------------------------
info "Installing Jaeger all-in-one into namespace '${JAEGER_NAMESPACE}'..."
helm upgrade --install jaeger-all-in-one jaegertracing/jaeger \
  --namespace "${JAEGER_NAMESPACE}" \
  --values "${ROOT_DIR}/observability/jaeger-values.yaml" \
  --wait \
  --timeout 3m

success "Jaeger installed."

# -----------------------------------------------------------------------
# 5. Enable tracing in Consul ProxyDefaults
# -----------------------------------------------------------------------
info "Applying ProxyDefaults with Jaeger tracing enabled..."
kubectl apply -f "${ROOT_DIR}/consul/proxydefaults-tracing.yaml"
success "ProxyDefaults updated — Envoy sidecars will now emit traces to Jaeger."

# -----------------------------------------------------------------------
# 6. Wait for all pods
# -----------------------------------------------------------------------
info "Waiting for Prometheus pods to be ready..."
kubectl rollout status deployment/kube-prometheus-stack-grafana        -n "${PROM_NAMESPACE}" --timeout=120s
kubectl rollout status deployment/kube-prometheus-stack-kube-state-metrics -n "${PROM_NAMESPACE}" --timeout=120s

info "Waiting for Jaeger pod to be ready..."
kubectl rollout status deployment/jaeger-all-in-one -n "${JAEGER_NAMESPACE}" --timeout=180s

# -----------------------------------------------------------------------
# 7. Print port-forward commands
# -----------------------------------------------------------------------
echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  Observability stack is ready!${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""
echo "  Open dashboards with these port-forward commands (run each in"
echo "  a separate terminal tab):"
echo ""
echo -e "  ${CYAN}# Grafana  — http://localhost:3000  (admin / admin)${NC}"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n ${PROM_NAMESPACE}"
echo ""
echo -e "  ${CYAN}# Prometheus — http://localhost:9090${NC}"
echo "  kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n ${PROM_NAMESPACE}"
echo ""
echo -e "  ${CYAN}# Jaeger UI  — http://localhost:16686${NC}"
echo "  kubectl port-forward svc/jaeger-all-in-one 16686:16686 -n ${JAEGER_NAMESPACE}"
echo ""
echo "  Navigate to Grafana → Dashboards → Consul →"
echo "    'consul-mesh-poc — Envoy Per-Subset Metrics'"
echo ""
