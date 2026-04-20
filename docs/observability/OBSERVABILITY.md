# OBSERVABILITY

This guide explains how to use the production observability stack for `consul-mesh-poc`.

It covers:
- how to open Grafana, Prometheus, and Jaeger
- how to read the per-subset traffic dashboard
- which PromQL queries are expected to work in this repo
- how to generate traffic so the dashboard shows live data
- what to check when the dashboard says `No data`

## What This Stack Monitors

Step 13 uses:
- Prometheus via `kube-prometheus-stack`
- Grafana with a custom dashboard: `consul-mesh-poc — Envoy Per-Subset Metrics`
- Jaeger all-in-one for distributed tracing
- Consul dataplane / Envoy sidecar metrics on port `20200`

For the Step 10 blue-green demo, the important metric dimension is:
- `consul_destination_service_subset`

That label is emitted on the caller-side mesh metrics for traffic headed to `api-server`.

## Open The Tools

Run these in separate terminals:

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring
kubectl port-forward svc/jaeger-all-in-one 16686:16686 -n default
```

Then open:
- Grafana: <http://localhost:3000>
- Prometheus: <http://localhost:9090>
- Jaeger: <http://localhost:16686>

## Grafana Dashboard

Navigate to:
- `Dashboards`
- `Consul`
- `consul-mesh-poc — Envoy Per-Subset Metrics`

This dashboard is provisioned from:
- `observability/grafana-dashboard-consul.json`

## How To Read The Dashboard

### Traffic Split

- `Request Rate per Subset (req/s)` shows live request throughput per subset.
- `Traffic Split (last 5 min)` shows the recent percentage split as a pie chart.
- `Active Connections per Subset` shows current upstream connections by subset.

For Step 10 blue-green, you should normally see either `v1` or `v2` depending on the active cutover target.

### Latency

- `Latency Percentiles per Subset (ms)` shows p50, p95, and p99.
- `Average Latency per Subset (ms)` shows the rolling average latency.

### Error Rate

- `Error Rate per Subset (req/s)` shows 4xx and 5xx rates.
- `Error Percentage per Subset (last 5 min)` shows the ratio of 5xx responses to total requests.

## Verified PromQL Queries

These are the queries this repo is using successfully.

### Request Rate Per Subset

```promql
sum by (consul_destination_service_subset) (
  rate(envoy_cluster_upstream_rq_total{
    consul_destination_service="api-server",
    consul_destination_service_subset=~"v1|v2|variant-a|variant-b"
  }[1m])
)
```

### Recent Traffic Split

```promql
sum by (consul_destination_service_subset) (
  increase(envoy_cluster_upstream_rq_total{
    consul_destination_service="api-server",
    consul_destination_service_subset=~"v1|v2|variant-a|variant-b"
  }[5m])
)
```

### p95 Latency Per Subset

```promql
histogram_quantile(0.95,
  sum by (consul_destination_service_subset, le) (
    rate(envoy_cluster_upstream_rq_time_bucket{
      consul_destination_service="api-server",
      consul_destination_service_subset=~"v1|v2|variant-a|variant-b"
    }[1m])
  )
)
```

### Active Connections Per Subset

```promql
sum by (consul_destination_service_subset) (
  envoy_cluster_upstream_cx_active{
    consul_destination_service="api-server",
    consul_destination_service_subset=~"v1|v2|variant-a|variant-b"
  }
)
```

### 5xx Error Rate Per Subset

```promql
sum by (consul_destination_service_subset) (
  rate(envoy_cluster_upstream_rq_xx{
    consul_destination_service="api-server",
    consul_destination_service_subset=~"v1|v2|variant-a|variant-b",
    envoy_response_code_class="5"
  }[1m])
)
```

### Error Percentage Per Subset

```promql
sum by (consul_destination_service_subset) (
  rate(envoy_cluster_upstream_rq_xx{
    consul_destination_service="api-server",
    consul_destination_service_subset=~"v1|v2|variant-a|variant-b",
    envoy_response_code_class="5"
  }[5m])
)
/
sum by (consul_destination_service_subset) (
  rate(envoy_cluster_upstream_rq_total{
    consul_destination_service="api-server",
    consul_destination_service_subset=~"v1|v2|variant-a|variant-b"
  }[5m])
)
```

## RED Metrics For This Demo

You can think about the dashboard in RED terms:

- Rate: `envoy_cluster_upstream_rq_total`
- Errors: `envoy_cluster_upstream_rq_xx`
- Duration: `envoy_cluster_upstream_rq_time_bucket`

For Step 10 blue-green, the useful grouping key is the destination subset label.

## Generate Traffic So The Dashboard Shows Data

If Grafana says `No data`, the first thing to check is whether any recent traffic has actually gone through `ui-app -> api-server`.

Use the helper script:

```bash
bash scripts/generate-api-traffic.sh
```

Heavier burst:

```bash
bash scripts/generate-api-traffic.sh --requests 50 --batches 8 --concurrency 20
```

Slower sustained traffic:

```bash
bash scripts/generate-api-traffic.sh --requests 10 --batches 30 --pause 2
```

This generates traffic from the `ui-app` pod to `api-server` inside the mesh, which is exactly what the dashboard queries observe.

## Blue-Green Verification

If Step 10 is routed to `v1`, the dashboard should show only `v1` traffic.

To flip traffic to `v2`:

```bash
bash scripts/blue-green-cutover.sh v2 --skip-build
```

Then generate traffic again:

```bash
bash scripts/generate-api-traffic.sh --requests 40 --batches 4
```

The dashboard should move from `v1` to `v2`.

To switch back:

```bash
bash scripts/blue-green-cutover.sh v1 --skip-build
```

## Prometheus Checks

Open Prometheus and verify the sidecar scrape targets:

1. Go to <http://localhost:9090/targets>
2. Look for the job `consul-envoy-sidecars`
3. Confirm `ui-app`, `api-server`, and `api-server-v2` are `UP`

Quick live query:

```bash
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=count by (consul_destination_service_subset) (envoy_cluster_upstream_rq_total{consul_destination_service="api-server"})' \
  | jq '.data.result'
```

If traffic has run recently, you should see `v1` or `v2` with a value.

## Jaeger Checks

Open Jaeger and:

1. Choose service `api-server`
2. Click `Find Traces`
3. Open any recent trace

You should see the mesh request path across the app and sidecar hops.

## Troubleshooting

### Grafana shows `No data`

Check these in order:

1. Generate traffic with `scripts/generate-api-traffic.sh`.
2. Confirm the Grafana time range includes the last few minutes.
3. Confirm Prometheus returns results for the request-rate query.
4. Confirm the `consul-envoy-sidecars` targets are `UP`.

### Prometheus targets are `DOWN`

This repo expects Consul sidecar metrics on `:20200/metrics` without metric merging.

Keep this setting in:
- `consul/helm-values.yaml`

Expected value:

```yaml
connectInject:
  metrics:
    defaultEnableMerging: false
```

If metric merging is enabled, app responses can pollute the sidecar metrics payload and Prometheus can reject the scrape.

### Grafana dashboard exists but panels stay blank

This repo’s dashboard is provisioned from file, so panel datasource bindings must point directly to the provisioned Prometheus datasource UID.

The current dashboard JSON already uses:

```json
"datasource": { "type": "prometheus", "uid": "prometheus" }
```

If you edit the dashboard JSON, re-run:

```bash
bash scripts/install-observability.sh
```

That refreshes the dashboard configmap and restarts Grafana so the provisioned dashboard reloads.