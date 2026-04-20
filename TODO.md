# TODO — consul-mesh-poc Session Tracker

> Last updated: Step 13 complete (full production observability)
> Use this file to resume work across sessions. Each step includes its status and the exact prompt to send to continue.

---

## Step Progress

| Step | Title                                    | Status      |
|------|------------------------------------------|-------------|
| 1    | Repo Scaffold                            | ✅ Complete  |
| 2    | Consul Helm Values + Install Script      | ✅ Complete  |
| 3    | api-server Application Code              | ✅ Complete  |
| 4    | api-server Kubernetes Manifests          | ✅ Complete  |
| 5    | ui-app Application Code                  | ✅ Complete  |
| 6    | ui-app Kubernetes Manifests + Intentions | ✅ Complete  |
| 7    | Consul Mesh Config Entries               | ✅ Complete  |
| 8    | Deploy Scripts                           | ✅ Complete  |
| 9    | docs/reference/CONSUL_NOTES.md           | ✅ Complete  |
| 10   | Blue-Green Deployment Demo               | ✅ Complete  |
| 11   | A/B Testing Demo                         | ✅ Complete  |
| 12   | Canary Deployment Demo                   | ✅ Complete  |
| 13   | Full Production Observability            | ✅ Complete  |
| 14   | KEDA Autoscaling with Consul Metrics     | ⬜ Pending   |

---

## Next Step to Execute

**Step 14 — KEDA Autoscaling with Consul Metrics**

---

## Step Details

### Step 1 — Repo Scaffold ✅
- Created all directories and empty files for the full project tree.
- Extra files added: `TODO.md`, `QUICKSTART.md`, `docs/setup/K8S.md`

### Step 2 — Consul Helm Values + Install Script ✅
Files to write:
- `consul/helm-values.yaml`
- `scripts/install-consul.sh`

### Step 3 — api-server Application Code ✅
Files to write:
- `api-server/package.json`
- `api-server/src/index.js`
- `api-server/src/db/cockroach.js`
- `api-server/src/routes/items.js`
- `api-server/Dockerfile`

### Step 4 — api-server Kubernetes Manifests ✅
Files to write:
- `api-server/k8s/deployment.yaml`
- `api-server/k8s/service.yaml`
- `api-server/k8s/servicedefaults.yaml`

### Step 5 — ui-app Application Code ✅
Files to write:
- `ui-app/package.json`
- `ui-app/server.js`
- `ui-app/src/index.html`

### Step 6 — ui-app Kubernetes Manifests + Intentions ✅
Files to write:
- `ui-app/k8s/deployment.yaml`
- `ui-app/k8s/service.yaml`
- `ui-app/k8s/serviceintentions.yaml`

### Step 7 — Consul Mesh Config Entries ✅
Files to write:
- `consul/proxydefaults.yaml`
- `consul/servicerouter.yaml`
- `consul/serviceresolver.yaml`
- `consul/ingressgateway.yaml`

### Step 8 — Deploy Scripts ✅
Files written:
- `scripts/deploy-all.sh`
- `scripts/teardown.sh`

### Step 9 — docs/reference/CONSUL_NOTES.md ✅
File written:
- `docs/reference/CONSUL_NOTES.md`

---

### Step 10 — Blue-Green Deployment Demo ✅
Goal: demonstrate a live blue-green cutover using the existing ui-app and api-server.

Artifacts written:
- `api-server/k8s/deployment.yaml` — updated: added `version: v1` pod label, `consul.hashicorp.com/service-meta-version: v1` annotation, `APP_VERSION: v1` env
- `api-server/k8s/deployment-v2.yaml` — new Deployment labelled `version: v2`, image `api-server:v2`, env `APP_VERSION: v2`
- `consul/servicerouter-blue-green.yaml` — ServiceRouter routing 100% to explicit subset (v1 or v2)
- `consul/serviceresolver-blue-green.yaml` — ServiceResolver with `v1` and `v2` subsets filtered by `Service.Meta.version`
- `api-server/src/index.js` — emits `X-Api-Version` response header based on `APP_VERSION` env
- `ui-app/server.js` — forwards `x-api-version` header from api-server to browser
- `ui-app/src/index.html` — version badge: blue for v1, green for v2
- `scripts/blue-green-cutover.sh` — patches ServiceRouter + ServiceResolver to flip all traffic between v1 and v2

---

### Step 11 — A/B Testing Demo ✅
Goal: split traffic between two variants based on a request header (e.g. `X-User-Group: beta`).

Artifacts written:
- `api-server/k8s/deployment-variant-b.yaml` — variant B Deployment with `APP_VARIANT=variant-b` and Consul `service-meta-variant`
- `consul/servicerouter-ab.yaml` — ServiceRouter matching `x-user-group: beta` and routing to subset `variant-b`
- `consul/serviceresolver-ab.yaml` — ServiceResolver defining `variant-a` / `variant-b` subsets from `Service.Meta.variant`
- `api-server/k8s/deployment.yaml` — updated with `APP_VARIANT=variant-a` and Consul `service-meta-variant`
- `api-server/src/index.js` — emits `X-Api-Variant` and reports variant on `/health`
- `api-server/src/routes/items.js` — variant B decorates item responses for a visible beta experience
- `ui-app/server.js` — forwards `x-api-variant` from the mesh-routed api response
- `ui-app/src/index.html` — beta toggle sends `X-User-Group: beta` and shows the responding variant
- `scripts/ab-switch.sh` — helper to enable, disable, or inspect A/B routing

Resume prompt:
> "We are on Step 11. Implement A/B testing demo artifacts. Use Consul ServiceRouter header-based routing to send requests with `X-User-Group: beta` to api-server variant-b. Update the UI to let the user toggle the beta header and show which variant responded."

---

### Step 12 — Canary Deployment Demo ✅
Goal: gradually shift traffic from v1 to a canary (v2) using weighted splits, visualised in real time.

Artifacts written:
- `consul/servicerouter-canary.yaml` — ServiceRouter for `/api/*` canary traffic without pinning a subset
- `consul/serviceresolver-canary.yaml` — ServiceResolver defining `v1` / `v2` subsets for canary routing
- `consul/servicesplitter-canary.yaml` — ServiceSplitter implementing weighted traffic between `v1` and `v2`
- `scripts/canary-promote.sh` — builds `api-server:v2`, applies canary config, and steps through 10 → 25 → 50 → 75 → 100% v2 traffic
- `scripts/canary-rollback.sh` — instantly restores 100% traffic to `v1`
- `api-server/src/routes/version.js` — `/api/version` endpoint returning the active pod version and variant
- `api-server/src/index.js` — mounts the new version endpoint
- `ui-app/src/canary.html` — dedicated canary page with live chart driven by `/api/version` responses
- `ui-app/server.js` — serves `/canary` without altering the existing index page

Resume prompt:
> "We are on Step 12. Implement canary deployment demo artifacts. Use Consul ServiceRouter weighted splits to gradually shift traffic from api-server v1 to v2. Add a promote script that increments weights, a rollback script, and a real-time visualisation in the UI showing v1 vs v2 hit counts."

---

### Step 13 — Full Production Observability ✅
Goal: replace the in-memory demo counter with a production-grade observability stack (Prometheus + Grafana + distributed tracing).

Planned artifacts:
- `observability/prometheus-values.yaml` — Helm values for `kube-prometheus-stack`; adds scrape annotations for Consul Envoy sidecar port `20200`
- `observability/grafana-dashboard-consul.json` — import of HashiCorp Consul dashboard (Grafana ID 13396); add custom panel for `envoy_cluster_upstream_rq_total{consul_destination_service_subset=~"v1|v2"}`
- `observability/jaeger-values.yaml` — Helm values for Jaeger all-in-one (or Tempo); configure Envoy to emit traces
- `consul/proxydefaults-tracing.yaml` — updated ProxyDefaults enabling Envoy tracing via Jaeger/Tempo endpoint
- `scripts/install-observability.sh` — installs the full stack via Helm; prints port-forward commands for Grafana (3000), Prometheus (9090), Jaeger (16686)
- `docs/observability/OBSERVABILITY.md` — guide: how to read the per-subset traffic split dashboard, how to query `rate(envoy_cluster_upstream_rq_total[1m])`, example PromQL for RED metrics

Key Envoy metrics to visualise:
- `envoy_cluster_upstream_rq_total{consul_destination_service_subset="v1|v2"}` — request rate per subset
- `envoy_cluster_upstream_rq_time_bucket` — latency histogram per subset
- `envoy_cluster_upstream_cx_active` — active connections per subset
- `envoy_cluster_upstream_rq_xx{envoy_response_code_class="5"}` — error rate

Resume prompt:
> "We are on Step 13. Set up production observability for the consul-mesh-poc. Install Prometheus + Grafana via kube-prometheus-stack Helm chart. Add a Grafana dashboard that shows real-time per-subset request rate (v1 vs v2) using Envoy metrics. Add Jaeger for distributed tracing and update ProxyDefaults to emit traces."

---

### Step 14 — KEDA Autoscaling with Consul Metrics ⬜
Goal: demonstrate event-driven autoscaling of `api-server` using KEDA, where Consul Envoy sidecar metrics (scraped by Prometheus) serve as the scaling signal. Show scale-up under synthetic load and scale-down at idle, visualised in Grafana.

**Prerequisite:** Step 13 observability stack must be running (Prometheus reachable at `http://prometheus-operated.monitoring.svc:9090`).

---

#### Sub-step Checklist

- [x] **14.1 — Install KEDA**
  - File: `scripts/install-keda.sh`
  - Add Helm repo `kedacore`, install chart `kedacore/keda` into namespace `keda`
  - Verify all CRDs are registered: `ScaledObject`, `TriggerAuthentication`, `ScaledJob`
  - Print `kubectl get scaledobject -A` and `kubectl get pods -n keda` for confirmation
  - _Validate:_ KEDA operator pod is Running before proceeding

- [ ] **14.2 — TriggerAuthentication for Prometheus**
  - File: `keda/triggerauthentication.yaml`
  - Kind: `TriggerAuthentication` in `default` namespace
  - Reference the in-cluster Prometheus service (`http://prometheus-operated.monitoring.svc:9090`)
  - No secret needed for unauthenticated Prometheus; include commented-out block for bearer-token auth as a production reference
  - _Validate:_ `kubectl describe triggerauthentication prometheus-trigger-auth`

- [ ] **14.3 — ScaledObject for api-server v1**
  - File: `keda/scaledobject-api-server.yaml`
  - `scaleTargetRef.name` must match Deployment name in `api-server/k8s/deployment.yaml`
  - Prometheus trigger: `rate(envoy_cluster_upstream_rq_total{consul_destination_service="api-server",consul_destination_service_subset="v1"}[1m])`
  - `threshold: "50"` (rps per replica), `minReplicaCount: 1`, `maxReplicaCount: 10`
  - `pollingInterval: 15`, `cooldownPeriod: 60`
  - _Validate:_ `kubectl describe scaledobject api-server` shows `Active: True` under load

- [ ] **14.4 — ScaledObject for api-server v2 (canary)**
  - File: `keda/scaledobject-api-server-v2.yaml`
  - Same structure as 14.3 but targets the v2 Deployment and filters subset `v2`
  - Allows v1 and v2 pods to scale independently during a canary rollout
  - _Validate:_ both ScaledObjects coexist without HPA conflict (`kubectl get hpa`)

- [ ] **14.5 — Update traffic-generation script**
  - File: `scripts/generate-api-traffic.sh` (existing file — update, do not replace)
  - Add `--rps <n>` flag (default: 10) and `--duration <s>` flag (default: 60)
  - Run load inside the cluster via `kubectl run` with `curlimages/curl` loop (no external dependency)
  - Print live replica count every 5 s during the test: `kubectl get deployment api-server -w`
  - Calls with no flags must behave identically to before (backward-compatible)
  - _Validate:_ `./generate-api-traffic.sh --rps 100 --duration 120` triggers scale-up

- [ ] **14.6 — Grafana dashboard for KEDA**
  - File: `observability/grafana-dashboard-keda.json`
  - Self-contained JSON, importable via the same mechanism as `grafana-dashboard-consul.json`
  - Required panels:
    1. Request rate per subset (v1/v2) — primary scaling signal (Envoy metric)
    2. Replica count over time — `kube_deployment_status_replicas{deployment=~"api-server.*"}`
    3. KEDA metric value — `keda_scaler_metrics_value{scaler="prometheus"}`
    4. Pod readiness timeline — `kube_pod_status_ready{pod=~"api-server.*"}` (scale-up latency)
    5. Scale events — annotation overlay sourced from Kubernetes events or a time-series marker
  - _Validate:_ dashboard imports cleanly; all panels resolve data during a load test

- [ ] **14.7 — KEDA Autoscaling guide**
  - File: `docs/observability/KEDA_AUTOSCALING.md`
  - Sections to cover:
    1. **Architecture overview** — KEDA components (operator, metrics adapter, ScaledObject, TriggerAuthentication) and how KEDA creates/manages the HPA internally
    2. **Why Consul/Envoy metrics** — L7 request-rate vs CPU/memory: reflects actual traffic pressure, not sidecar overhead; aware of Consul subsets
    3. **Prerequisites & installation** — link to Step 13; `install-keda.sh` walkthrough
    4. **Applying the ScaledObjects** — `kubectl apply -f keda/`; expected output
    5. **Running a load test** — `generate-api-traffic.sh --rps 100 --duration 120`; what to watch
    6. **Reading the Grafana dashboard** — panel-by-panel walkthrough; how to spot the scale lag
    7. **Tuning reference** — table of `pollingInterval`, `cooldownPeriod`, `threshold`, `minReplicaCount`, `maxReplicaCount` with recommended values per environment tier (dev / staging / prod)
    8. **Canary + autoscaling interaction** — how weighted Consul traffic splits affect per-subset rps and why independent ScaledObjects are needed
    9. **Troubleshooting** — `kubectl describe scaledobject`, KEDA operator logs, HPA events, common Prometheus query errors
    10. **Production considerations** — metric scrape lag, HPA conflict avoidance, KEDA version compatibility, Prometheus retention minimum
  - _Validate:_ all `kubectl` commands in the doc are copy-pasteable and correct

---

Key Prometheus metrics used:
- `rate(envoy_cluster_upstream_rq_total{consul_destination_service="api-server"}[1m])` — primary KEDA scale trigger
- `kube_deployment_status_replicas{deployment=~"api-server.*"}` — replica count for Grafana
- `keda_scaler_metrics_value` — KEDA's own scaler value exposed to Prometheus
- `kube_pod_status_ready` — pod readiness timeline for scale-up latency panel

Resume prompt:
> "We are on Step 14. Work through the checklist sub-steps in order: 14.1 install KEDA, 14.2 TriggerAuthentication, 14.3 ScaledObject v1, 14.4 ScaledObject v2, 14.5 update traffic script, 14.6 Grafana dashboard, 14.7 KEDA_AUTOSCALING.md. Implement one sub-step at a time and confirm before proceeding to the next."
