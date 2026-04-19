# TODO — consul-mesh-poc Session Tracker

> Last updated: Step 9 complete — ALL STEPS DONE ✅  
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

---

## Next Step to Execute

**All steps complete.** The project is fully built. Run `./scripts/install-consul.sh` then `./scripts/deploy-all.sh` to bring it up.

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
