# Observability Quickstart — consul-mesh-poc

This guide walks you through installing the full production observability stack on top of the running consul-mesh-poc cluster and verifying every component manually.

---

## What gets installed

| Component | Purpose | Default port |
|-----------|---------|-------------|
| **Prometheus** (kube-prometheus-stack) | Scrapes Envoy sidecar metrics from every injected pod | 9090 |
| **Grafana** (bundled with kube-prometheus-stack) | Visualises per-subset traffic, latency, and error rate | 3000 |
| **Jaeger all-in-one** | Collects distributed traces emitted by Envoy | 16686 |
| **ProxyDefaults (tracing)** | Consul CRD that tells every Envoy sidecar to emit Zipkin/B3 traces to Jaeger | — |

---

## Prerequisites

- consul-mesh-poc is fully deployed (`scripts/deploy-all.sh` completed successfully)
- `kubectl`, `helm` ≥ 3.12, and `curl` are in your `$PATH`
- Helm repos are reachable from your machine

Verify:

```bash
kubectl get pods -n consul          # all consul pods Running
kubectl get pods -n default         # api-server + ui-app Running
helm version --short
```

---

## Step 1 — Add Helm repos (one-time)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add jaegertracing        https://jaegertracing.github.io/helm-charts
helm repo update
```

---

## Step 2 — Install the full stack

Run the install script from the repo root:

```bash
chmod +x scripts/install-observability.sh
./scripts/install-observability.sh
```

The script:
1. Creates the `monitoring` namespace and installs `kube-prometheus-stack`
2. Creates a `consul-mesh-poc-dashboard` ConfigMap that Grafana's sidecar auto-loads
3. Installs Jaeger all-in-one in the `default` namespace (co-located with app pods so Envoy can reach it)
4. Applies `consul/proxydefaults-tracing.yaml` — this replaces `consul/proxydefaults.yaml` and enables Zipkin tracing to Jaeger

Expected output ends with:

```
[OK]    Observability stack is ready!
```

---

## Alternative: Install without Helm

Use this path when Helm is unavailable (CI runners, locked-down clusters, air-gapped environments).  
Skip Steps 1 and 2 above and follow this section instead; then continue from **Step 3** onwards as normal.

### A — Prometheus + Grafana via kube-prometheus raw manifests

`kube-prometheus` is the upstream raw-YAML equivalent of `kube-prometheus-stack`. Clone the release branch that matches your Kubernetes version:

```bash
# Choose the branch for your cluster — list at https://github.com/prometheus-operator/kube-prometheus
K8S_VERSION=$(kubectl version --short 2>/dev/null | awk '/Server/{print $3}' | cut -d. -f1,2)
# e.g. for Kubernetes 1.29 use release-0.13, for 1.30 use release-0.14
git clone --depth 1 --branch release-0.14 \
  https://github.com/prometheus-operator/kube-prometheus.git /tmp/kube-prometheus

# 1. Install CRDs and the monitoring namespace first
kubectl apply --server-side -f /tmp/kube-prometheus/manifests/setup

# 2. Wait until all CRDs are established
kubectl wait --for condition=Established --all CustomResourceDefinition \
  --namespace=monitoring --timeout=120s

# 3. Deploy the full stack
kubectl apply -f /tmp/kube-prometheus/manifests
```

This creates Prometheus, Alertmanager, Grafana, node-exporter, and kube-state-metrics in the `monitoring` namespace.

> **Custom Grafana datasource / dashboard:** The kube-prometheus Grafana ships without the Consul custom datasource pre-wired. After the stack is running, patch it manually:

```bash
# 1. Verify Grafana is ready
kubectl rollout status deployment/grafana -n monitoring --timeout=120s

# 2. Forward Grafana to localhost
kubectl port-forward svc/grafana 3000:3000 -n monitoring &

# 3. Import the custom dashboard via API (admin / admin is the default)
curl -sX POST http://admin:admin@localhost:3000/api/dashboards/import \
  -H 'Content-Type: application/json' \
  -d "{\"dashboard\":$(cat observability/grafana-dashboard-consul.json),\"overwrite\":true,\"folderId\":0}"
```

> **Prometheus scrape config:** The custom `consul-envoy-sidecars` scrape job from `prometheus-values.yaml` cannot be applied via Helm values here. Instead, add it as an `additionalScrapeConfigs` Secret that the Prometheus CR picks up:

```bash
# Extract just the scrape job YAML from prometheus-values.yaml and save it
cat <<'EOF' > /tmp/envoy-scrape.yaml
- job_name: consul-envoy-sidecars
  kubernetes_sd_configs:
    - role: pod
      namespaces:
        names: [default]
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_annotation_consul_hashicorp_com_connect_inject]
      action: keep
      regex: "true"
    - source_labels: [__address__]
      action: replace
      regex: "([^:]+)(?::\\d+)?"
      replacement: "$1:20200"
      target_label: __address__
    - source_labels: [__meta_kubernetes_pod_label_app]
      target_label: app
    - source_labels: [__meta_kubernetes_pod_label_version]
      target_label: version
    - source_labels: [__meta_kubernetes_pod_annotation_consul_hashicorp_com_service_meta_version]
      target_label: consul_service_subset
      regex: "(.+)"
EOF

kubectl create secret generic consul-envoy-scrape \
  --from-file=consul-envoy-scrape.yaml=/tmp/envoy-scrape.yaml \
  -n monitoring --dry-run=client -o yaml | kubectl apply -f -

# Patch the Prometheus CR to reference the secret
kubectl patch prometheus k8s -n monitoring --type=merge -p '
{
  "spec": {
    "additionalScrapeConfigs": {
      "name": "consul-envoy-scrape",
      "key": "consul-envoy-scrape.yaml"
    }
  }
}'
```

This setup assumes Consul keeps Envoy/dataplane metrics separate from the
application's own `/metrics` endpoint. Leave
`connectInject.metrics.defaultEnableMerging: false` in
`consul/helm-values.yaml`; if merging is enabled, the `ui-app` HTML response and
the `api-server` local scrape failure text are mixed into `:20200/metrics`, and
Prometheus marks those sidecar targets as down.

---

### B — Jaeger all-in-one via kubectl (inline manifest)

No chart needed — apply this manifest directly:

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger-all-in-one
  namespace: default
  labels:
    app: jaeger
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
        - name: jaeger
          image: jaegertracing/all-in-one:1.55.0
          ports:
            - name: zipkin
              containerPort: 9411
            - name: query
              containerPort: 16686
            - name: agent-compact
              containerPort: 6831
              protocol: UDP
          env:
            - name: COLLECTOR_ZIPKIN_HOST_PORT
              value: ":9411"
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-all-in-one-query
  namespace: default
spec:
  selector:
    app: jaeger
  ports:
    - name: query
      port: 80
      targetPort: 16686
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-all-in-one-collector
  namespace: default
spec:
  selector:
    app: jaeger
  ports:
    - name: zipkin
      port: 9411
      targetPort: 9411
EOF

kubectl rollout status deployment/jaeger-all-in-one -n default --timeout=120s
```

---

### C — Apply ProxyDefaults and dashboard ConfigMap (same for both paths)

These steps are identical regardless of whether Helm was used:

```bash
# Enable Envoy tracing
kubectl apply -f consul/proxydefaults-tracing.yaml

# Restart injected pods to pick up the new proxy config
kubectl rollout restart deployment/api-server
kubectl rollout restart deployment/ui-app

# (Optional) create ConfigMap for auto-loaded Grafana dashboard
kubectl create configmap consul-mesh-poc-dashboard \
  --from-file=consul-mesh-poc.json=observability/grafana-dashboard-consul.json \
  --namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
```

Continue from **Step 3 — Open the dashboards** above.

---

## Step 3 — Open the dashboards

Run each port-forward in a **separate terminal tab** and keep them open.

### Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
```

Open: <http://localhost:3000>  
Login: `admin` / `admin`

Navigate to **Dashboards → Consul → consul-mesh-poc — Envoy Per-Subset Metrics**.

### Prometheus

```bash
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
```

Open: <http://localhost:9090>

### Jaeger UI

```bash
kubectl port-forward svc/jaeger-all-in-one 16686:16686 -n default
```

Open: <http://localhost:16686>

---

## Step 4 — Verify metrics are flowing

### Check Envoy metrics target in Prometheus

1. Open <http://localhost:9090/targets>
2. Look for the job **`consul-envoy-sidecars`** — all `api-server` and `ui-app` pods should show **UP**

If a pod shows DOWN, confirm the pod has the Consul inject annotation:

```bash
kubectl get pod -l app=api-server -o jsonpath='{.items[0].metadata.annotations}' | jq .
# Should contain: "consul.hashicorp.com/connect-inject": "true"
```

### Manually query key metrics

These queries use Consul's native destination labels from the caller sidecar metrics.
For the existing blue-green demo in Step 10, the subset split shows up under
`consul_destination_service_subset` for traffic headed to `api-server`.

```bash
# Request rate by subset (works after sending some traffic)
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=sum by (consul_destination_service_subset) (rate(envoy_cluster_upstream_rq_total{consul_destination_service="api-server",consul_destination_service_subset=~"v1|v2|variant-a|variant-b"}[1m]))' \
  | jq '.data.result'

# p95 latency
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=histogram_quantile(0.95, sum by (consul_destination_service_subset, le) (rate(envoy_cluster_upstream_rq_time_bucket{consul_destination_service="api-server",consul_destination_service_subset=~"v1|v2|variant-a|variant-b"}[1m])))' \
  | jq '.data.result'

# 5xx error rate
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=sum by (consul_destination_service_subset) (rate(envoy_cluster_upstream_rq_xx{consul_destination_service="api-server",consul_destination_service_subset=~"v1|v2|variant-a|variant-b",envoy_response_code_class="5"}[1m]))' \
  | jq '.data.result'
```

### Generate traffic to produce data

```bash
# Hit the API server a few times through the Consul ingress gateway
INGRESS=$(kubectl get svc consul-ingress-gateway -n consul -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
for i in $(seq 1 50); do curl -s http://${INGRESS}/api/items -o /dev/null; done
```

---

## Step 5 — Verify distributed tracing in Jaeger

1. Open <http://localhost:16686>
2. In the **Service** drop-down select `api-server`
3. Click **Find Traces** — you should see a list of recent traces
4. Click any trace to expand the span waterfall

Each trace shows the full path: `ui-app → envoy → api-server`.

### Confirm Envoy is emitting traces

If no traces appear, confirm ProxyDefaults was applied:

```bash
kubectl get proxydefaults global -o yaml | grep -A5 tracing
```

You should see `jaeger_zipkin` in the output. If not, re-apply:

```bash
kubectl apply -f consul/proxydefaults-tracing.yaml
```

Then restart the injected pods to pick up the new proxy config:

```bash
kubectl rollout restart deployment/api-server
kubectl rollout restart deployment/ui-app
```

---

## Step 6 — Grafana dashboard walkthrough

The **consul-mesh-poc — Envoy Per-Subset Metrics** dashboard has four sections:

### Traffic Split

| Panel | What it shows |
|-------|--------------|
| Request Rate per Subset (req/s) | Live time-series — one line per subset (v1, v2, variant-a, variant-b) |
| Traffic Split (last 5 min) | Pie chart showing the percentage of requests going to each subset |
| Active Connections per Subset | Gauge showing current open TCP connections to each subset |

### Latency

| Panel | What it shows |
|-------|--------------|
| Latency Percentiles per Subset (ms) | p50 / p95 / p99 per subset |
| Average Latency per Subset (ms) | Rolling average over the scrape window |

### Error Rate

| Panel | What it shows |
|-------|--------------|
| Error Rate per Subset (req/s) | 5xx and 4xx rates side by side |
| Error Percentage per Subset | Gauge: green < 1 %, yellow 1–5 %, red > 5 % |

### Key PromQL queries

```promql
# Request rate per subset
sum by (consul_destination_service_subset) (
  rate(envoy_cluster_upstream_rq_total{consul_destination_service="api-server", consul_destination_service_subset=~"v1|v2|variant-a|variant-b"}[1m])
)

# p99 latency per subset
histogram_quantile(0.99,
  sum by (consul_destination_service_subset, le) (
    rate(envoy_cluster_upstream_rq_time_bucket{consul_destination_service="api-server", consul_destination_service_subset=~"v1|v2|variant-a|variant-b"}[1m])
  )
)

# Active connections per subset
sum by (consul_destination_service_subset) (
  envoy_cluster_upstream_cx_active{consul_destination_service="api-server", consul_destination_service_subset=~"v1|v2|variant-a|variant-b"}
)

# 5xx error rate per subset
sum by (consul_destination_service_subset) (
  rate(envoy_cluster_upstream_rq_xx{consul_destination_service="api-server", consul_destination_service_subset=~"v1|v2|variant-a|variant-b", envoy_response_code_class="5"}[1m])
)
```

---

## Teardown

To remove the observability stack without touching the app:

```bash
helm uninstall kube-prometheus-stack -n monitoring
helm uninstall jaeger-all-in-one     -n default
kubectl delete namespace monitoring
kubectl delete configmap consul-mesh-poc-dashboard -n monitoring 2>/dev/null || true

# Restore original proxydefaults (no tracing)
kubectl apply -f consul/proxydefaults.yaml
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Prometheus target DOWN | Pod missing `consul.hashicorp.com/connect-inject: "true"` annotation |
| No metrics for a subset label | Pod missing `version:` label or `consul.hashicorp.com/service-meta-version:` annotation |
| Jaeger shows no traces | ProxyDefaults not applied, or pods not restarted after applying it |
| Grafana shows "No data" | Prometheus not yet scraping — wait 60 s and send traffic first |
| `jaeger-all-in-one` pod OOMKilled | Increase memory limit in `observability/jaeger-values.yaml` |
