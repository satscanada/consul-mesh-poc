#!/usr/bin/env bash
# install-consul-offline.sh — installs Consul OSS on Amazon EKS
#                             from a locally bundled Helm chart (no internet required).
#
# The chart tarball must exist under artifacts/ in the repo root.
# If the file is not found the script will search for any consul-*.tgz in that
# directory and use the newest one automatically.
#
# Prerequisites (must be present on the machine running this script):
#   - kubectl  configured with a valid EKS kubeconfig
#              (e.g. via: aws eks update-kubeconfig --region <region> --name <cluster>)
#   - helm     3.x
#   - aws      CLI (used only to confirm connectivity; not required if SKIP_AWS_CHECK=true)
#
# Override defaults via environment variables before running:
#   DEPLOY_ENV=dev|prod           # skip the interactive prompt
#   EKS_CLUSTER_NAME=my-cluster   # used in the context check hint only
#   CONSUL_CHART_TGZ=consul-1.9.6.tgz
#   SKIP_AWS_CHECK=true           # skip the aws-cli preflight check
#   VALUES_FILE=/path/to/custom-values.yaml  # fully override values file selection
#
# Run from the repo root: ./scripts/install-consul-offline.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts"
CONSUL_NAMESPACE="consul"
RELEASE_NAME="consul"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
SKIP_AWS_CHECK="${SKIP_AWS_CHECK:-false}"

# ── Deployment environment selection ─────────────────────────────────────────
# If VALUES_FILE is set explicitly, skip the env prompt and use it directly.
if [[ -z "${VALUES_FILE:-}" ]]; then
  if [[ -n "${DEPLOY_ENV:-}" ]]; then
    # Non-interactive: set via env var (useful in CI)
    ENV_CHOICE="${DEPLOY_ENV}"
  else
    echo ""
    echo "  Select deployment environment:"
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  1) dev   — single server, minimal resources  (dev / staging)   │"
    echo "  │  2) prod  — 3-server HA, multi-AZ, production-grade resources   │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    read -r -p "  Enter choice [1/2]: " env_input
    case "${env_input}" in
      1|dev)  ENV_CHOICE="dev"  ;;
      2|prod) ENV_CHOICE="prod" ;;
      *) echo "ERROR: Invalid choice '${env_input}'. Enter 1 (dev) or 2 (prod)." >&2; exit 1 ;;
    esac
  fi

  case "${ENV_CHOICE}" in
    dev)
      VALUES_FILE="${REPO_ROOT}/consul/helm-values-eks-dev.yaml"
      echo "==> Environment : dev  (${VALUES_FILE})"
      ;;
    prod)
      VALUES_FILE="${REPO_ROOT}/consul/helm-values-eks.yaml"
      echo "==> Environment : prod (${VALUES_FILE})"
      ;;
    *)
      echo "ERROR: DEPLOY_ENV must be 'dev' or 'prod'." >&2; exit 1
      ;;
  esac
else
  echo "==> Using custom values file: ${VALUES_FILE}"
fi

[[ -f "${VALUES_FILE}" ]] || { echo "ERROR: Values file not found: ${VALUES_FILE}" >&2; exit 1; }

# ── Locate the chart tarball ──────────────────────────────────────────────────
# Prefer an exact version if set via env var, e.g.:
#   CONSUL_CHART_TGZ=consul-1.9.6.tgz ./scripts/install-consul-offline.sh
if [[ -n "${CONSUL_CHART_TGZ:-}" ]]; then
  CHART="${ARTIFACTS_DIR}/${CONSUL_CHART_TGZ}"
else
  # Auto-detect: pick the newest consul-*.tgz in artifacts/
  CHART=$(ls -t "${ARTIFACTS_DIR}"/consul-*.tgz 2>/dev/null | head -1 || true)
fi

if [[ -z "${CHART}" || ! -f "${CHART}" ]]; then
  echo "ERROR: No Consul chart tarball found in ${ARTIFACTS_DIR}/" >&2
  echo "       Download it once (with internet access) by running:" >&2
  echo "         helm pull hashicorp/consul --destination artifacts/" >&2
  exit 1
fi

CHART_FILENAME="$(basename "${CHART}")"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo "==> Checking prerequisites"
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found in PATH" >&2; exit 1; }
command -v helm    >/dev/null 2>&1 || { echo "ERROR: helm not found in PATH"    >&2; exit 1; }

echo "==> Verifying kubectl context"
CURRENT_CONTEXT=$(kubectl config current-context)
echo "    Active context: ${CURRENT_CONTEXT}"

# Warn if the context does not look like an EKS context (arn:aws:eks:...)
if [[ "${CURRENT_CONTEXT}" != *"eks"* && "${CURRENT_CONTEXT}" != *"arn:aws"* ]]; then
  echo "WARNING: current context '${CURRENT_CONTEXT}' does not appear to be an EKS cluster."
  if [[ -n "${EKS_CLUSTER_NAME}" ]]; then
    echo "         To switch to your EKS cluster, run:"
    echo "           aws eks update-kubeconfig --region <region> --name ${EKS_CLUSTER_NAME}"
  fi
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# Verify cluster is reachable
echo "==> Verifying cluster connectivity"
kubectl cluster-info --request-timeout=10s > /dev/null || {
  echo "ERROR: Cannot reach the Kubernetes API server." >&2
  echo "       Ensure your kubeconfig is correct and the EKS cluster is accessible." >&2
  exit 1
}

# Verify AWS CLI can reach EKS (optional — skipped in strict air-gap environments)
if [[ "${SKIP_AWS_CHECK}" != "true" ]] && command -v aws >/dev/null 2>&1; then
  echo "==> Verifying AWS identity"
  aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null \
    && echo "    AWS identity confirmed" \
    || echo "    WARNING: aws sts get-caller-identity failed — continuing anyway."
fi

echo "==> Using local chart  : ${CHART_FILENAME}"
echo "    Using values file  : ${VALUES_FILE}"
echo "    (No internet access required)"

# ── Namespace ─────────────────────────────────────────────────────────────────
echo "==> Creating namespace '${CONSUL_NAMESPACE}' (idempotent)"
kubectl create namespace "${CONSUL_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── EKS node group sanity check ───────────────────────────────────────────────
echo "==> Cluster node status"
kubectl get nodes -o wide

# Node count sanity check — threshold depends on selected environment
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready " || true)
if [[ "${ENV_CHOICE:-prod}" == "prod" ]] && (( READY_NODES < 3 )); then
  echo ""
  echo "WARNING: Only ${READY_NODES} Ready node(s) found."
  echo "         The prod values file sets server.replicas=3 with hard AZ anti-affinity."
  echo "         Servers may remain Pending unless you have at least 3 nodes (one per AZ)."
  echo "         To use a single-node setup, re-run and choose the 'dev' environment."
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
elif [[ "${ENV_CHOICE:-prod}" == "dev" ]] && (( READY_NODES < 1 )); then
  echo "ERROR: No Ready nodes found. Cannot proceed." >&2
  exit 1
fi

# ── Install ───────────────────────────────────────────────────────────────────
echo "==> Installing / upgrading Consul via Helm (offline)"
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
echo " Consul UI — port-forward (for quick access):"
echo ""
echo "   kubectl port-forward svc/consul-ui -n consul 8500:80"
echo "   Then open: http://localhost:8500"
echo ""
echo " Ingress Gateway NLB hostname:"
echo "   kubectl get svc consul-ingress-gateway -n ${CONSUL_NAMESPACE} \\"
echo "     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
echo "================================================================"
