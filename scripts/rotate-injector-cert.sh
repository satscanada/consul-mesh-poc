#!/usr/bin/env bash
# =============================================================================
# rotate-injector-cert.sh
#
# Fixes the Consul connect-injector webhook TLS certificate when it has
# expired or is otherwise invalid.  This happens when the system clock is
# skewed or when the cluster has been offline long enough for the short-lived
# auto-generated cert to expire.
#
# What it does:
#   1. Deletes the TLS secret — the injector immediately regenerates it
#   2. Restarts the connect-injector deployment — picks up the new cert and
#      patches the MutatingWebhookConfiguration caBundle
#   3. Waits for the rollout to complete and prints a verification summary
#
# Usage:
#   ./scripts/rotate-injector-cert.sh
#   CONSUL_NAMESPACE=consul ./scripts/rotate-injector-cert.sh
# =============================================================================
set -euo pipefail

CONSUL_NS="${CONSUL_NAMESPACE:-consul}"
CERT_SECRET="consul-connect-inject-webhook-cert"
INJECTOR_DEPLOY="consul-connect-injector"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-90s}"

# ── helpers ──────────────────────────────────────────────────────────────────
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
step()  { printf '\n\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { red "ERROR: '$1' is required but not found."; exit 1; }
}

require kubectl

bold "=== Consul Injector TLS Certificate Rotation ==="
echo "  Namespace : ${CONSUL_NS}"
echo "  Secret    : ${CERT_SECRET}"
echo "  Deployment: ${INJECTOR_DEPLOY}"

# ── Step 1: delete the expired secret ────────────────────────────────────────
step "Deleting expired TLS secret"
if kubectl get secret "${CERT_SECRET}" -n "${CONSUL_NS}" >/dev/null 2>&1; then
  kubectl delete secret "${CERT_SECRET}" -n "${CONSUL_NS}"
  echo "  Deleted ${CERT_SECRET}"
else
  echo "  Secret not found — may have already been removed, continuing."
fi

# ── Step 2: wait for the injector to regenerate the secret ───────────────────
step "Waiting for injector to regenerate the TLS secret"
for i in $(seq 1 20); do
  if kubectl get secret "${CERT_SECRET}" -n "${CONSUL_NS}" >/dev/null 2>&1; then
    AGE=$(kubectl get secret "${CERT_SECRET}" -n "${CONSUL_NS}" \
      -o jsonpath='{.metadata.creationTimestamp}')
    echo "  New secret created at: ${AGE}"
    break
  fi
  printf "  Waiting... (%d/20)\r" "${i}"
  sleep 2
done

# ── Step 3: restart the injector deployment ───────────────────────────────────
step "Restarting ${INJECTOR_DEPLOY} deployment"
kubectl rollout restart deployment/"${INJECTOR_DEPLOY}" -n "${CONSUL_NS}"

# ── Step 4: wait for rollout to complete ─────────────────────────────────────
step "Waiting for rollout (timeout: ${ROLLOUT_TIMEOUT})"
kubectl rollout status deployment/"${INJECTOR_DEPLOY}" \
  -n "${CONSUL_NS}" \
  --timeout="${ROLLOUT_TIMEOUT}"

# ── Step 5: verify ────────────────────────────────────────────────────────────
step "Verification"
echo ""
echo "  Pods:"
kubectl get pods -n "${CONSUL_NS}" -l "app=consul,component=connect-injector" \
  --no-headers \
  -o custom-columns="    NAME:.metadata.name,READY:.status.containerStatuses[0].ready,AGE:.metadata.creationTimestamp"

echo ""
echo "  Webhook caBundle fingerprint (first 40 chars):"
kubectl get mutatingwebhookconfiguration consul-connect-injector \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null \
  | base64 --decode \
  | openssl x509 -noout -dates 2>/dev/null \
  || echo "    (could not decode — verify manually with: kubectl get mutatingwebhookconfiguration consul-connect-injector -o yaml)"

echo ""
green "✔ Certificate rotation complete."
echo "  You can now re-run the deploy:"
echo "    ./scripts/deploy-all.sh"
