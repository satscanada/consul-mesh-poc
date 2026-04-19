# TODO — consul-mesh-poc Session Tracker

> Last updated: Steps 10–12 queued — blue-green, A/B testing, canary demos  
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
| 9    | CONSUL_NOTES.md                          | ✅ Complete  |
| 10   | Blue-Green Deployment Demo               | ⏳ Pending   |
| 11   | A/B Testing Demo                         | ⏳ Pending   |
| 12   | Canary Deployment Demo                   | ⏳ Pending   |

---

## Next Step to Execute

**Step 10 — Blue-Green Deployment Demo.**  
Prompt to resume:
> "We are on Step 10. Implement blue-green deployment demo artifacts using the existing ui-app and api-server. Use Consul ServiceRouter / ServiceResolver to split traffic between a v1 and v2 version of api-server. Add a toggle in the UI to switch between versions and visualize which backend responded. Include all k8s manifests and Consul config entries needed."

---

## Step Details

### Step 1 — Repo Scaffold ✅
- Created all directories and empty files for the full project tree.
- Extra files added: `TODO.md`, `QUICKSTART.md`, `K8S.md`

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

### Step 9 — CONSUL_NOTES.md ✅
File written:
- `CONSUL_NOTES.md`

---

### Step 10 — Blue-Green Deployment Demo ⏳
Goal: demonstrate a live blue-green cutover using the existing ui-app and api-server.

Planned artifacts:
- `api-server-v2/` (or a v2 image tag) — same API, different response payload/colour indicator
- `api-server/k8s/deployment-v2.yaml` — second Deployment labelled `version: v2`
- `consul/servicerouter-blue-green.yaml` — ServiceRouter that routes 100% to v1 or v2 based on a header / weight
- `consul/serviceresolver-blue-green.yaml` — ServiceResolver subsets for `v1` and `v2`
- Updated `ui-app/src/index.html` — shows which version responded (colour badge: blue / green)
- `scripts/blue-green-cutover.sh` — one-command toggle between v1 and v2

Resume prompt:
> "We are on Step 10. Implement blue-green deployment demo artifacts using the existing ui-app and api-server. Use Consul ServiceRouter/ServiceResolver subsets to route between api-server v1 and v2. Add a visible version badge in the UI (blue for v1, green for v2) and a cutover script. Show it in the Consul UI."

---

### Step 11 — A/B Testing Demo ⏳
Goal: split traffic between two variants based on a request header (e.g. `X-User-Group: beta`).

Planned artifacts:
- `api-server/k8s/deployment-variant-b.yaml` — variant B Deployment (different items response or feature flag)
- `consul/servicerouter-ab.yaml` — ServiceRouter with `headerPreconditions` routing beta users to variant B
- `consul/serviceresolver-ab.yaml` — ServiceResolver subsets `variant-a` / `variant-b`
- Updated `ui-app/src/index.html` — toggle to send `X-User-Group: beta` header; shows which variant served the response
- `scripts/ab-switch.sh` — helper to apply/remove the A/B router config

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
