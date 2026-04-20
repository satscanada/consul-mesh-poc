# TODO — consul-mesh-poc Session Tracker

> Last updated: Step 11 complete (A/B testing demo)
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
| 12   | Canary Deployment Demo                   | ⏳ Pending   |
| 13   | Full Production Observability            | ✅ Complete  |

---

## Next Step to Execute

**Step 12 — Canary Deployment Demo.**  
Prompt to resume:
> "We are on Step 12. Implement canary deployment demo artifacts. Use Consul ServiceRouter weighted splits to gradually shift traffic from api-server v1 to v2. Add a promote script that increments weights, a rollback script, and a real-time visualisation in the UI showing v1 vs v2 hit counts."

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

### Step 12 — Canary Deployment Demo ⏳
Goal: gradually shift traffic from v1 to a canary (v2) using weighted splits, visualised in real time.

Planned artifacts:
- `consul/servicerouter-canary.yaml` — ServiceRouter with weight-based split (e.g. 90/10 → 50/50 → 0/100)
- `scripts/canary-promote.sh` — steps through traffic weights (10 → 25 → 50 → 75 → 100%) with a confirmation prompt at each stage
- `scripts/canary-rollback.sh` — instantly shifts 100% back to v1
- Updated `ui-app/src/index.html` — live pie/bar chart showing v1 vs v2 response counts (uses a `/api/version` endpoint)
- `api-server/src/routes/version.js` — `/api/version` endpoint that returns the pod's version label

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
