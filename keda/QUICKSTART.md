# KEDA Autoscaling — Quickstart

> **Step 14** of the consul-mesh-poc series.  
> This guide walks you from zero to a running, validated KEDA autoscaling demo in the order: install → build images → deploy → test → validate.

---

## Contents

- [Prerequisites Checklist](#prerequisites-checklist)
- [Phase 1 — Install KEDA](#phase-1--install-keda)
- [Phase 2 — Build & Push Container Images](#phase-2--build--push-container-images)
- [Phase 3 — Deploy api-server v1 & v2](#phase-3--deploy-api-server-v1--v2)
- [Phase 4 — Apply KEDA Manifests](#phase-4--apply-keda-manifests)
- [Phase 5 — Run a Load Test](#phase-5--run-a-load-test)
- [Phase 6 — Validate Autoscaling](#phase-6--validate-autoscaling)
- [Phase 7 — Import the Grafana Dashboard](#phase-7--import-the-grafana-dashboard)
- [Phase 8 — Canary + Autoscaling Combined Demo](#phase-8--canary--autoscaling-combined-demo)
- [Teardown](#teardown)
- [File Reference](#file-reference)

---

## Prerequisites Checklist

Run these checks before starting. All boxes must be green.

```bash
# 1. kubectl is connected to the right cluster
kubectl config current-context

# 2. Consul is installed and healthy (Steps 1–8)
kubectl get pods -n consul

# 3. api-server and ui-app are running (Steps 3–6)
kubectl get pods -n default -l app=api-server
kubectl get pods -n default -l app=ui-app

# 4. Step 13 observability stack is running
kubectl get pods -n monitoring
kubectl get svc prometheus-operated -n monitoring

# 5. Helm ≥ 3.x
helm version --short
```

Expected state before continuing:

| Resource | Namespace | Status |
|----------|-----------|--------|
| consul pods | consul | Running |
| api-server | default | 1/1 Running |
| ui-app | default | 1/1 Running |
| prometheus-operated | monitoring | Running |
| grafana | monitoring | Running |

---

## Phase 1 — Install KEDA

KEDA is installed via Helm into a dedicated `keda` namespace.

```bash
./scripts/install-keda.sh
```

The script:
1. Adds the `kedacore` Helm repo.
2. Installs `kedacore/keda` into the `keda` namespace.
3. Waits for the operator and metrics-adapter pods to be `Ready`.
4. Verifies all four CRDs are registered.

**Verify:**

```bash
# Pods
kubectl get pods -n keda
```

Expected:
```
NAME                                      READY   STATUS    RESTARTS
keda-operator-xxxxxxxxxx-xxxxx            1/1     Running   0
keda-operator-metrics-apiserver-xxxxx     1/1     Running   0
```

```bash
# CRDs
kubectl get crd | grep keda.sh
```

Expected:
```
clustertriggerauthentications.keda.sh
scaledjobs.keda.sh
scaledobjects.keda.sh
triggerauthentications.keda.sh
```

> **Troubleshoot:** if pods stay in `Pending`, check node resources: `kubectl describe pod -n keda <pod-name>`.

---

## Phase 2 — Build & Push Container Images

KEDA needs both `api-server:v1` and `api-server:v2` images available in the cluster.

### Option A — local cluster (kind / minikube / Docker Desktop)

```bash
# v1 — stable release
docker build \
  --build-arg APP_VERSION=v1 \
  -t api-server:v1 \
  ./api-server

# v2 — canary / new release
docker build \
  --build-arg APP_VERSION=v2 \
  -t api-server:v2 \
  ./api-server
```

For **kind**, load images directly into the cluster:

```bash
kind load docker-image api-server:v1
kind load docker-image api-server:v2
```

For **minikube**:

```bash
minikube image load api-server:v1
minikube image load api-server:v2
```

### Option B — remote registry

```bash
REGISTRY="your-registry.example.com/consul-mesh-poc"

docker build --build-arg APP_VERSION=v1 -t "${REGISTRY}/api-server:v1" ./api-server
docker push "${REGISTRY}/api-server:v1"

docker build --build-arg APP_VERSION=v2 -t "${REGISTRY}/api-server:v2" ./api-server
docker push "${REGISTRY}/api-server:v2"
```

Then update the `image:` field in `api-server/k8s/deployment.yaml` and `api-server/k8s/deployment-v2.yaml` to use the full registry path.

**Verify images are accessible:**

```bash
# For kind/minikube — confirm image is present
docker images | grep api-server
```

---

## Phase 3 — Deploy api-server v1 & v2

Apply Consul mesh config, then both Deployments and their Services.

```bash
# 1. Consul ServiceResolver + ServiceSplitter (canary config — needed for subset routing)
kubectl apply -f consul/serviceresolver-canary.yaml
kubectl apply -f consul/servicesplitter-canary.yaml
kubectl apply -f consul/servicerouter-canary.yaml

# 2. api-server v1 (stable)
kubectl apply -f api-server/k8s/deployment.yaml
kubectl apply -f api-server/k8s/service.yaml
kubectl apply -f api-server/k8s/servicedefaults.yaml

# 3. api-server v2 (canary)
kubectl apply -f api-server/k8s/deployment-v2.yaml

# 4. ui-app (traffic source)
kubectl apply -f ui-app/k8s/deployment.yaml
kubectl apply -f ui-app/k8s/service.yaml
kubectl apply -f ui-app/k8s/serviceintentions.yaml
```

**Verify:**

```bash
kubectl get pods -n default
```

Expected:
```
NAME                             READY   STATUS    RESTARTS
api-server-xxxxxxxxxx-xxxxx      2/2     Running   0   # 2/2 = app + Envoy sidecar
api-server-v2-xxxxxxxxxx-xxxxx   2/2     Running   0
ui-app-xxxxxxxxxx-xxxxx          2/2     Running   0
```

> **`2/2` is required.** `1/2` means the Consul Envoy sidecar is not injected — verify `consul.hashicorp.com/connect-inject: "true"` is present in the pod annotations.

```bash
# Check Consul service registration
kubectl exec -n consul -it consul-server-0 -- consul catalog services
# api-server and api-server-sidecar-proxy should appear
```

---

## Phase 4 — Apply KEDA Manifests

```bash
kubectl apply -f keda/
```

Expected output:
```
triggerauthentication.keda.sh/prometheus-trigger-auth created
scaledobject.keda.sh/api-server created
scaledobject.keda.sh/api-server-v2 created
```

**Inspect the ScaledObjects:**

```bash
kubectl get scaledobject -n default
```

```
NAME             SCALETARGETKIND   SCALETARGETNAME   MIN   MAX   READY   ACTIVE
api-server       Deployment        api-server        1     10    True    False
api-server-v2    Deployment        api-server-v2     1     10    True    False
```

`ACTIVE: False` at idle is **correct** — it becomes `True` once the Envoy metric exceeds the 50 rps threshold.

**Inspect the generated HPAs:**

```bash
kubectl get hpa -n default
```

```
NAME                    REFERENCE                  TARGETS       MINPODS   MAXPODS   REPLICAS
keda-hpa-api-server     Deployment/api-server      0/50 (avg)    1         10        1
keda-hpa-api-server-v2  Deployment/api-server-v2   0/50 (avg)    1         10        1
```

> KEDA owns these HPAs. Do not edit or delete them manually.

**Verify the Prometheus query returns data (requires at least one prior request):**

```bash
# Port-forward Prometheus (run in a separate terminal)
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090

# Then open http://localhost:9090 and run this query:
# sum(rate(envoy_cluster_upstream_rq_total{consul_destination_service="api-server",consul_destination_service_subset="v1"}[1m]))
```

> If the result is `no data`, send a few test requests first (see Phase 5 warm-up).

---

## Phase 5 — Run a Load Test

### Warm-up (seed Prometheus with initial data)

```bash
# Send a small batch through the mesh to prime the Envoy counters
./scripts/generate-api-traffic.sh --requests 20 --batches 3
```

Wait ~30 s for Prometheus to scrape the new counter values.

### KEDA scale-out test — 100 rps for 120 s

```bash
./scripts/generate-api-traffic.sh --rps 100 --duration 120
```

What happens:
1. A temporary `curlimages/curl` pod named `keda-load-<timestamp>` is launched inside the cluster.
2. It fires 100 HTTP requests per second at `http://api-server.default.svc:3000/api/items`.
3. The script prints live replica counts every 5 s.
4. On exit the curl pod is deleted automatically.

**Expected terminal output (excerpt):**

```
KEDA load-test mode: 100 rps for 120 s -> http://api-server.default.svc:3000/api/items
Launching in-cluster curl pod: keda-load-1745000000

Watching replica count (Ctrl-C to stop early):
NAME             READY   DESIRED
api-server       1       1
api-server-v2    1       1
---
NAME             READY   DESIRED
api-server       1       2        ← KEDA scaling out
api-server-v2    1       1
---
NAME             READY   DESIRED
api-server       2       2        ← new pod is Ready
api-server-v2    1       1
---
...
Load test finished. Cleaning up pod keda-load-1745000000
Check KEDA dashboard in Grafana for scale events.
```

### High-load test — 500 rps (expect ~10 replicas)

```bash
./scripts/generate-api-traffic.sh --rps 500 --duration 90
```

At 500 rps ÷ 50 threshold = 10 desired replicas (the configured maximum).

---

## Phase 6 — Validate Autoscaling

Run all of these checks during or just after the load test.

### 6.1 — ScaledObject is Active

```bash
kubectl get scaledobject api-server -n default
# ACTIVE column should be True during load
```

### 6.2 — Replica count increased

```bash
kubectl get deployment api-server -n default
# READY should be > 1 during load (e.g. 2/2 at 100 rps)
```

### 6.3 — HPA is acting on the external metric

```bash
kubectl describe hpa keda-hpa-api-server -n default | grep -A5 "Metrics:"
```

Expected (during load):
```
Metrics:  ( current / target )
  "envoy_rps_api_server_v1" (target average value):  87500m / 50
```

`87500m` = 87.5 (milliunits of rps) → KEDA requests ⌈87.5 / 50⌉ = 2 replicas.

### 6.4 — Pods registered in Consul

```bash
kubectl exec -n consul -it consul-server-0 -- \
  consul catalog service api-server
# Should list all running api-server pods with their addresses
```

### 6.5 — Scale-down after cooldown

After the load test ends, wait `cooldownPeriod` (60 s) + one `pollingInterval` (15 s):

```bash
watch -n5 kubectl get deployment api-server -n default
# READY count should return to 1 within ~90 s of load stopping
```

### 6.6 — Check KEDA operator logs for errors

```bash
kubectl logs -n keda -l app=keda-operator --tail=50 | grep -i error
# Should be empty
```

### 6.7 — Verify no duplicate HPAs exist

```bash
kubectl get hpa -n default
# Exactly two HPAs: keda-hpa-api-server and keda-hpa-api-server-v2
# No manually created HPAs targeting the same Deployments
```

---

## Phase 7 — Import the Grafana Dashboard

```bash
# Port-forward Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000  (default credentials: admin / prom-operator)
```

**Import steps:**

1. In Grafana sidebar → **Dashboards → Import**.
2. Click **Upload JSON file**.
3. Select `observability/grafana-dashboard-keda.json`.
4. Set the **Prometheus** data source to your in-cluster instance.
5. Click **Import**.

**Dashboard panels and what to look for during a load test:**

| Panel | What to watch |
|-------|---------------|
| **Request Rate per Subset** | v1 line climbs under load; v2 line stays low (weight-proportional) |
| **KEDA Scaler Metric Value** | Rises above 50 → triggers scale-out |
| **Replica Count Over Time** | Step up when load starts; step down ~90 s after load stops |
| **Pod Readiness Timeline** | Gap between desired↑ and ready↑ = scale-up latency (aim < 30 s) |
| **Scale Events (Δ)** | Orange bars = scale-out; negative bars = scale-in |

---

## Phase 8 — Canary + Autoscaling Combined Demo

This phase demonstrates v1 and v2 scaling **independently** as the canary traffic weight shifts.

### Step 8.1 — Start canary at 10 %

```bash
./scripts/canary-promote.sh
# Choose step: 10  (10% to v2, 90% to v1)
```

### Step 8.2 — Generate load

```bash
./scripts/generate-api-traffic.sh --rps 200 --duration 180
```

Expected outcome at 200 rps with 10 % canary split:

| Deployment | Traffic | Expected replicas |
|------------|---------|-------------------|
| api-server (v1) | ~180 rps | ⌈180/50⌉ = **4** |
| api-server-v2 | ~20 rps | **1** (below threshold) |

### Step 8.3 — Promote to 50 %

While the load test is still running, open another terminal:

```bash
./scripts/canary-promote.sh
# Choose step: 50
```

Expected outcome at 200 rps with 50 % split:

| Deployment | Traffic | Expected replicas |
|------------|---------|-------------------|
| api-server (v1) | ~100 rps | ⌈100/50⌉ = **2** |
| api-server-v2 | ~100 rps | ⌈100/50⌉ = **2** |

Observe both Deployments scale symmetrically.

### Step 8.4 — Validate independent scaling

```bash
kubectl get deployment api-server api-server-v2 -n default
```

### Step 8.5 — Rollback

```bash
./scripts/canary-rollback.sh
# Restores 100% traffic to v1; api-server-v2 scales back to minReplicas=1
```

---

## Teardown

Remove only KEDA resources (preserves the rest of the demo):

```bash
kubectl delete -f keda/
helm uninstall keda -n keda
kubectl delete namespace keda
```

Full environment teardown:

```bash
./scripts/teardown.sh
```

---

## File Reference

| File | Purpose |
|------|---------|
| `keda/triggerauthentication.yaml` | KEDA auth config for in-cluster Prometheus |
| `keda/scaledobject-api-server.yaml` | ScaledObject for api-server v1; threshold 50 rps |
| `keda/scaledobject-api-server-v2.yaml` | ScaledObject for api-server v2 (canary) |
| `scripts/install-keda.sh` | Installs KEDA via Helm, verifies CRDs |
| `scripts/generate-api-traffic.sh` | Traffic generator; `--rps`/`--duration` for in-cluster load |
| `scripts/canary-promote.sh` | Steps canary traffic weight up (10→25→50→75→100) |
| `scripts/canary-rollback.sh` | Instantly restores 100 % traffic to v1 |
| `observability/grafana-dashboard-keda.json` | 5-panel Grafana dashboard |
| `docs/observability/KEDA_AUTOSCALING.md` | Full reference guide (architecture, tuning, troubleshooting) |
| `api-server/k8s/deployment.yaml` | api-server v1 Deployment (scaleTarget for v1 ScaledObject) |
| `api-server/k8s/deployment-v2.yaml` | api-server v2 Deployment (scaleTarget for v2 ScaledObject) |
| `consul/servicesplitter-canary.yaml` | Consul ServiceSplitter for weighted v1/v2 traffic |
| `consul/serviceresolver-canary.yaml` | Consul ServiceResolver defining v1/v2 subsets |
