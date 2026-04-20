#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="${NAMESPACE:-default}"
CANARY_ROUTER="${REPO_ROOT}/consul/servicerouter-canary.yaml"
CANARY_RESOLVER="${REPO_ROOT}/consul/serviceresolver-canary.yaml"
CANARY_SPLITTER="${REPO_ROOT}/consul/servicesplitter-canary.yaml"
VARIANT_B_DEPLOY="${REPO_ROOT}/api-server/k8s/deployment-variant-b.yaml"

if kubectl get deployment api-server-variant-b -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Removing leftover A/B deployment before rollback..."
  kubectl delete -f "${VARIANT_B_DEPLOY}" --ignore-not-found
fi

echo "Reapplying canary config entries..."
kubectl apply -f "${CANARY_RESOLVER}"
kubectl apply -f "${CANARY_ROUTER}"
kubectl apply -f "${CANARY_SPLITTER}"

echo "Rolling back to 100% stable traffic (v1)..."
kubectl patch servicesplitter api-server -n "${NAMESPACE}" --type='merge' -p \
  '{"spec":{"splits":[{"weight":100,"serviceSubset":"v1"},{"weight":0,"serviceSubset":"v2"}]}}'

kubectl get servicesplitter api-server -n "${NAMESPACE}" \
  -o jsonpath='{range .spec.splits[*]}- {.serviceSubset}: {.weight}{"%\n"}{end}'
