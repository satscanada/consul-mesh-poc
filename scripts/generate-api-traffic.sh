#!/usr/bin/env bash
# =============================================================================
# generate-api-traffic.sh
#
# Generates real mesh traffic from ui-app to api-server so the Grafana
# dashboard panels have fresh data to render.
#
# Usage:
#   ./scripts/generate-api-traffic.sh
#   ./scripts/generate-api-traffic.sh --requests 40 --batches 6
#   ./scripts/generate-api-traffic.sh --requests 20 --concurrency 5 --pause 2
#
# Environment overrides:
#   NAMESPACE=default
#   APP_LABEL=ui-app
#   API_PATH=/api/items
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
APP_LABEL="${APP_LABEL:-ui-app}"
CONTAINER="ui-app"
API_PATH="${API_PATH:-/api/items}"
REQUESTS=20
CONCURRENCY=10
BATCHES=5
PAUSE_SECONDS=1

usage() {
  cat <<'EOF'
Usage:
  ./scripts/generate-api-traffic.sh [options]

Options:
  --requests <n>      Requests per batch (default: 20)
  --concurrency <n>   Concurrent requests per batch (default: 10)
  --batches <n>       Number of batches to send (default: 5)
  --pause <seconds>   Pause between batches (default: 1)
  --path <path>       ui-app path to hit (default: /api/items)
  --namespace <ns>    Kubernetes namespace (default: default)
  --help              Show this help

Examples:
  ./scripts/generate-api-traffic.sh
  ./scripts/generate-api-traffic.sh --requests 50 --batches 8
  ./scripts/generate-api-traffic.sh --path /api/items --concurrency 20
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --requests)
      REQUESTS="$2"
      shift 2
      ;;
    --concurrency)
      CONCURRENCY="$2"
      shift 2
      ;;
    --batches)
      BATCHES="$2"
      shift 2
      ;;
    --pause)
      PAUSE_SECONDS="$2"
      shift 2
      ;;
    --path)
      API_PATH="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ERROR: required command not found: %s\n' "$1" >&2
    exit 1
  }
}

require kubectl

POD="$(kubectl get pods -n "$NAMESPACE" -l "app=${APP_LABEL}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$POD" ]]; then
  printf 'ERROR: no pod found for app=%s in namespace=%s\n' "$APP_LABEL" "$NAMESPACE" >&2
  exit 1
fi

printf 'Generating traffic via pod %s in namespace %s\n' "$POD" "$NAMESPACE"
printf 'Path=%s requests/batch=%s concurrency=%s batches=%s pause=%ss\n' \
  "$API_PATH" "$REQUESTS" "$CONCURRENCY" "$BATCHES" "$PAUSE_SECONDS"

for batch in $(seq 1 "$BATCHES"); do
  printf '\n[batch %s/%s] sending %s requests\n' "$batch" "$BATCHES" "$REQUESTS"

  kubectl exec -n "$NAMESPACE" "$POD" -c "$CONTAINER" -- \
    env REQUESTS="$REQUESTS" CONCURRENCY="$CONCURRENCY" API_PATH="$API_PATH" \
    node -e '
const http = require("http");
const requests = Math.max(1, Number(process.env.REQUESTS || 1));
const concurrency = Math.max(1, Number(process.env.CONCURRENCY || 1));
const path = process.env.API_PATH || "/api/items";
const target = `http://127.0.0.1:4000${path}`;

let launched = 0;
let completed = 0;
let succeeded = 0;
let failed = 0;

function finish() {
  completed += 1;
  if (launched < requests) {
    fire();
    return;
  }
  if (completed === requests) {
    console.log(JSON.stringify({ target, requests, succeeded, failed }));
  }
}

function fire() {
  launched += 1;
  http.get(target, (res) => {
    res.resume();
    if (res.statusCode && res.statusCode < 500) {
      succeeded += 1;
    } else {
      failed += 1;
    }
    finish();
  }).on("error", () => {
    failed += 1;
    finish();
  });
}

for (let i = 0; i < Math.min(concurrency, requests); i += 1) {
  fire();
}
'

  if [[ "$batch" -lt "$BATCHES" ]]; then
    sleep "$PAUSE_SECONDS"
  fi
done

printf '\nTraffic generation complete.\n'
printf 'Refresh Grafana: Consul -> consul-mesh-poc — Envoy Per-Subset Metrics\n'
printf 'Useful query:\n'
printf '  sum by (consul_destination_service_subset) (rate(envoy_cluster_upstream_rq_total{consul_destination_service="api-server"}[1m]))\n'