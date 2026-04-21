# KEDA Autoscaling with Consul / Envoy Metrics

> **Step 14** of the consul-mesh-poc series.  
> Prerequisite: [Step 13 Observability stack](OBSERVABILITY.md) must be running — Prometheus reachable at `http://prometheus-operated.monitoring.svc:9090`.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Why Consul / Envoy Metrics](#2-why-consul--envoy-metrics)
3. [Prerequisites & Installation](#3-prerequisites--installation)
4. [Applying the ScaledObjects](#4-applying-the-scaledobjects)
5. [Running a Load Test](#5-running-a-load-test)
6. [Reading the Grafana Dashboard](#6-reading-the-grafana-dashboard)
7. [Tuning Reference](#7-tuning-reference)
8. [Canary + Autoscaling Interaction](#8-canary--autoscaling-interaction)
9. [Troubleshooting](#9-troubleshooting)
10. [Production Considerations](#10-production-considerations)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│  Kubernetes cluster                                       │
│                                                           │
│  ┌─────────────┐   scrape    ┌─────────────────────────┐ │
│  │ Envoy (sidecar)  ──────►  │ Prometheus              │ │
│  │ :20200 /metrics│          │ (monitoring namespace)  │ │
│  └─────────────┘            └──────────┬──────────────┘ │
│                                         │ PromQL query   │
│  ┌─────────────────────────────────────▼──────────────┐  │
│  │  KEDA                                              │  │
│  │  ┌──────────────┐  ┌────────────────────────────┐  │  │
│  │  │  Operator    │  │  Metrics Adapter (HPA ext.)│  │  │
│  │  └──────┬───────┘  └────────────┬───────────────┘  │  │
│  │         │                       │                   │  │
│  │  ┌──────▼───────────────────────▼───────────────┐  │  │
│  │  │  ScaledObject (api-server / api-server-v2)   │  │  │
│  │  │  → creates & manages HPA automatically       │  │  │
│  │  └──────────────────────┬───────────────────────┘  │  │
│  └─────────────────────────┼────────────────────────┘  │
│                             │ scale                      │
│  ┌──────────────────────────▼────────────────────────┐  │
│  │  Deployment: api-server / api-server-v2           │  │
│  └───────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

**Key components:**

| Component | Role |
|-----------|------|
| **KEDA Operator** | Watches `ScaledObject` CRDs; creates/updates/removes the underlying HPA |
| **KEDA Metrics Adapter** | Exposes custom metric values to the Kubernetes HPA controller via the external metrics API |
| **ScaledObject** | Declares the scaling target, trigger type (Prometheus), metric query, and threshold |
| **TriggerAuthentication** | Stores auth credentials (or empty for unauthenticated Prometheus) used by the scaler |

KEDA does **not** replace the HPA — it creates one HPA per `ScaledObject` and keeps it in sync.

---

## 2. Why Consul / Envoy Metrics

| Signal | Source | Advantage |
|--------|--------|-----------|
| **CPU / Memory** | `metrics-server` | Easy, but reflects sidecar + OS overhead, not actual traffic |
| **Envoy `upstream_rq_total`** | Consul-injected Envoy sidecar | Measures real L7 request rate; per-Consul-subset awareness |
| **Custom app metric** | Application `/metrics` endpoint | Accurate, but requires code changes per service |

Using `envoy_cluster_upstream_rq_total` means:

- Scale-up starts as soon as requests arrive — before CPU saturates.
- Each Consul traffic subset (`v1`, `v2`) is metered independently, so a 10 % canary subset can scale independently from the stable release.
- No application code changes needed — Envoy emits this metric automatically.

**PromQL used as KEDA trigger:**

```promql
sum(rate(envoy_cluster_upstream_rq_total{
  consul_destination_service="api-server",
  consul_destination_service_subset="v1"
}[1m]))
```

---

## 3. Prerequisites & Installation

1. **Step 13 observability stack running** — verify Prometheus is up:

   ```bash
   kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus
   ```

2. **Install KEDA** (already done in sub-step 14.1):

   ```bash
   ./scripts/install-keda.sh
   ```

   Expected output includes:
   ```
   NAME                              READY   STATUS    RESTARTS
   keda-operator-...                 1/1     Running   0
   keda-operator-metrics-apiserver   1/1     Running   0
   ```

3. **Verify CRDs:**

   ```bash
   kubectl get crd | grep keda
   # scaledobjects.keda.sh
   # scaledjobs.keda.sh
   # triggerauthentications.keda.sh
   # clustertriggerauthentications.keda.sh
   ```

---

## 4. Applying the ScaledObjects

Apply all KEDA manifests from the `keda/` directory:

```bash
kubectl apply -f keda/
```

Expected output:
```
triggerauthentication.keda.sh/prometheus-trigger-auth created
scaledobject.keda.sh/api-server created
scaledobject.keda.sh/api-server-v2 created
```

Verify the ScaledObjects are registered:

```bash
kubectl get scaledobject -n default
```

```
NAME             SCALETARGETKIND   SCALETARGETNAME   MIN   MAX   TRIGGERS     AUTHENTICATION             READY   ACTIVE
api-server       Deployment        api-server        1     10    prometheus   prometheus-trigger-auth    True    False
api-server-v2    Deployment        api-server-v2     1     10    prometheus   prometheus-trigger-auth    True    False
```

`ACTIVE: False` at idle is expected — it becomes `True` once the metric exceeds the threshold.

Check the generated HPA:

```bash
kubectl get hpa -n default
```

```
NAME                    REFERENCE                  TARGETS         MINPODS   MAXPODS   REPLICAS
keda-hpa-api-server     Deployment/api-server      0/50 (avg)      1         10        1
keda-hpa-api-server-v2  Deployment/api-server-v2   0/50 (avg)      1         10        1
```

---

## 5. Running a Load Test

### Quick (batch mode — existing behaviour)

```bash
./scripts/generate-api-traffic.sh --requests 50 --batches 8
```

### KEDA load-test mode (in-cluster, high rps)

```bash
./scripts/generate-api-traffic.sh --rps 100 --duration 120
```

This command:
1. Launches a temporary `curlimages/curl` pod inside the cluster that fires 100 rps for 120 s directly at the `api-server` Service.
2. Prints live replica counts every 5 s so you can watch scale-out happen without leaving the terminal.
3. Cleans up the curl pod when done.

Watch KEDA react in real time (separate terminal):

```bash
kubectl get deployment api-server api-server-v2 -n default -w
```

Watch scale events:

```bash
kubectl describe scaledobject api-server -n default
kubectl get events -n default --sort-by='.lastTimestamp' | grep -i keda
```

---

## 6. Reading the Grafana Dashboard

Import `observability/grafana-dashboard-keda.json` into Grafana (same process as the Consul dashboard). It contains five panels:

### Panel 1 — Request Rate per Subset (v1 / v2)

- **Metric:** `sum(rate(envoy_cluster_upstream_rq_total{...}[1m]))`
- The red threshold line at 50 rps marks when KEDA will request a second replica.
- During a canary rollout the v2 line grows proportionally to the traffic weight in `ServicSplitter`.

### Panel 2 — KEDA Scaler Metric Value

- **Metric:** `keda_scaler_metrics_value{scaler="prometheus"}`
- This is the raw value KEDA reads before dividing by `threshold` to compute desired replicas.
- Useful for verifying KEDA is actually receiving metrics from Prometheus.

### Panel 3 — Replica Count Over Time

- **Metrics:** `kube_deployment_status_replicas` (current) and `kube_deployment_spec_replicas` (desired)
- Step changes = KEDA scale event. A gap between desired and current = pods still starting.

### Panel 4 — Pod Readiness Timeline (Scale-up Latency)

- **Metric:** `kube_pod_status_ready{condition="true"}`
- The lag between "desired" rising in Panel 3 and the ready count catching up here is your scale-up latency — typically 10–30 s for a warmed image.

### Panel 5 — Scale Events (Desired Replica Δ)

- **Metric:** `deriv(kube_deployment_spec_replicas[2m])`
- Positive bars = scale-out, negative = scale-in. Use this as an event overlay when correlating with traffic spikes.

---

## 7. Tuning Reference

| Parameter | Description | Dev | Staging | Prod |
|-----------|-------------|-----|---------|------|
| `pollingInterval` | How often KEDA polls the metric (seconds) | 15 | 15 | 30 |
| `cooldownPeriod` | Seconds to wait before scaling down | 30 | 60 | 300 |
| `threshold` | Requests per second per replica | 20 | 50 | 100 |
| `minReplicaCount` | Floor on replicas (0 = scale-to-zero) | 1 | 1 | 2 |
| `maxReplicaCount` | Ceiling on replicas | 5 | 10 | 50 |
| Prometheus `[range]` | Window in `rate()` query | `30s` | `1m` | `2m` |

**Scale-to-zero (`minReplicaCount: 0`):** Allowed by KEDA but incompatible with Consul Connect — the Envoy sidecar requires at least one pod to maintain the service registration. Keep `minReplicaCount: 1` for Consul mesh services.

---

## 8. Canary + Autoscaling Interaction

During a canary rollout managed by `consul/servicesplitter-canary.yaml`, the `ServiceSplitter` sends e.g. 10 % of traffic to the `v2` subset. This means:

- At 100 rps total: v1 receives ~90 rps, v2 receives ~10 rps.
- `api-server` ScaledObject sees 90 rps → desired replicas = ⌈90/50⌉ = 2.
- `api-server-v2` ScaledObject sees 10 rps → desired replicas = 1 (below threshold).

As the canary weight increases:

| v2 weight | v1 rps | v2 rps | v1 replicas | v2 replicas |
|-----------|--------|--------|-------------|-------------|
| 10 % | 90 | 10 | 2 | 1 |
| 25 % | 75 | 25 | 2 | 1 |
| 50 % | 50 | 50 | 1 | 1 |
| 75 % | 25 | 75 | 1 | 2 |
| 100 % | 0 | 100 | 1 (min) | 2 |

Each ScaledObject independently targets its own Deployment, so there is no HPA conflict — confirmed with:

```bash
kubectl get hpa -n default
# Expect one HPA per ScaledObject; KEDA prevents duplicate HPA for same Deployment
```

**Important:** do not create a manual HPA targeting the same Deployment as a `ScaledObject`. KEDA owns the HPA and will reconcile it back on any conflict.

---

## 9. Troubleshooting

### ScaledObject not becoming Active

```bash
kubectl describe scaledobject api-server -n default
```

Look for events like:
- `unable to get external metric` → Prometheus query error; test the query directly in Grafana/Prometheus UI.
- `error connecting to server` → check `serverAddress` in the ScaledObject matches the in-cluster Prometheus URL.

### KEDA operator logs

```bash
kubectl logs -n keda -l app=keda-operator --tail=100
```

### HPA events

```bash
kubectl describe hpa keda-hpa-api-server -n default
```

Look for `FailedGetExternalMetric` events.

### Test the Prometheus query manually

```bash
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090 &
# Then open http://localhost:9090 and run:
# sum(rate(envoy_cluster_upstream_rq_total{consul_destination_service="api-server",consul_destination_service_subset="v1"}[1m]))
```

### Common Prometheus query errors

| Error | Cause | Fix |
|-------|-------|-----|
| `no data` at idle | Envoy only emits `upstream_rq_total` after at least one request | Send a test request first |
| `unknown label consul_destination_service_subset` | Envoy metric label names differ across Consul versions | Check actual label names with `envoy_cluster_upstream_rq_total` in Prometheus |
| `parse error` | YAML multi-line query formatting issue | Use `>-` block scalar in YAML or flatten to one line |

### Verify TriggerAuthentication

```bash
kubectl describe triggerauthentication prometheus-trigger-auth -n default
```

---

## 10. Production Considerations

| Topic | Recommendation |
|-------|----------------|
| **Metric scrape lag** | Prometheus scrapes Envoy every 30 s by default. With `pollingInterval: 15`, KEDA may see stale data. Set Prometheus scrape interval to ≤ 15 s for the `api-server` job, or increase `pollingInterval` to 30 s. |
| **HPA conflict avoidance** | Never manually create an HPA for a Deployment managed by a `ScaledObject`. KEDA will overwrite it. |
| **KEDA version compatibility** | This setup targets KEDA v2.x. `ScaledObject` API version `keda.sh/v1alpha1` is stable in v2.x. Do not mix KEDA v1 and v2 resources. |
| **Prometheus retention minimum** | Grafana dashboard uses `now-30m` as default range. Prometheus retention must be at least `2h`. Default kube-prometheus-stack retention is `24h` — no action needed for dev. |
| **Scale-to-zero** | Avoid `minReplicaCount: 0` with Consul Connect. A scaled-to-zero service loses its Consul registration and will not receive traffic when scaled back up until the first request triggers registration — causing dropped requests. |
| **Multi-namespace** | `TriggerAuthentication` is namespaced. If `api-server` is in a different namespace, deploy a matching `TriggerAuthentication` there, or use `ClusterTriggerAuthentication` for cluster-wide sharing. |
| **Canary stability gate** | Consider adding a Prometheus alert (via Alertmanager) that fires if the error rate on `v2` exceeds 5 % during a canary promotion, and integrate it as a rollback trigger in `scripts/canary-rollback.sh`. |
