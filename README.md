# consul-mesh-poc

A learning POC for **HashiCorp Consul Service Mesh on Kubernetes**, built as a practical replacement study for Istio.

---

## What This Is

A minimal but complete two-service application deployed on Docker Desktop Kubernetes with Consul handling:

- **mTLS** between services (via Envoy sidecars)
- **Service discovery** through the Consul catalog
- **Traffic intentions** (replaces Istio `AuthorizationPolicy`)
- **Service routing / resolution** primitives (replaces Istio `VirtualService`)
- **Ingress** via Consul IngressGateway (replaces Istio `Gateway` + `VirtualService`)

---

## Services

| Service | Stack | Role |
|---------|-------|------|
| `api-server` | Node.js / Express | CRUD REST API for an `items` entity backed by CockroachDB Cloud |
| `ui-app` | Node.js / Express + vanilla HTML | Single-page frontend; proxies `/api/*` server-side through the mesh sidecar |

---

## Architecture

```
Browser
   │
   ▼
[IngressGateway :8080]   ← Consul IngressGateway (LoadBalancer on localhost)
   │
   ▼ (mTLS via Envoy)
[ui-app pod]
  ├── ui-app container   (serves index.html, proxies /api/* to api-server)
  └── envoy sidecar
         │
         ▼ (mTLS via Envoy)
     [api-server pod]
       ├── api-server container  (Express CRUD API)
       └── envoy sidecar
                │
                ▼ (TLS, direct)
         [CockroachDB Cloud]
```

Consul Intentions allow only `ui-app → api-server`. All other service-to-service traffic is denied.

---

## Tech Stack

| Component | Version |
|-----------|---------|
| Consul OSS | 1.17.x+ |
| Consul Helm Chart | 1.3.x+ |
| Kubernetes | 1.27+ (Docker Desktop) |
| Helm | 3.x |
| Node.js | 20 (Alpine) |
| CockroachDB Cloud | Postgres-compatible |

---

## Project Structure

```
consul-mesh-poc/
├── api-server/
│   ├── src/
│   │   ├── routes/items.js      # CRUD routes for items entity
│   │   ├── db/cockroach.js      # pg Pool + query helper
│   │   └── index.js             # Express app entry point
│   ├── Dockerfile
│   ├── package.json
│   └── k8s/
│       ├── deployment.yaml      # Consul inject annotation, secret mount
│       ├── service.yaml         # ClusterIP :3000
│       └── servicedefaults.yaml # Consul CRD — protocol: http
├── ui-app/
│   ├── src/
│   │   └── index.html           # Vanilla JS SPA
│   ├── server.js                # Static server + /api/* proxy
│   ├── Dockerfile
│   ├── package.json
│   └── k8s/
│       ├── deployment.yaml      # Consul inject annotation
│       ├── service.yaml         # ClusterIP :8080
│       └── serviceintentions.yaml # Allow ui-app → api-server
├── consul/
│   ├── helm-values.yaml         # Consul OSS Helm config (dc1, mTLS, UI, metrics)
│   ├── proxydefaults.yaml       # Global mTLS strict + protocol http
│   ├── servicerouter.yaml       # Route /health on api-server
│   ├── serviceresolver.yaml     # Default resolver, 5s connect timeout
│   └── ingressgateway.yaml      # Expose ui-app on port 8080
├── scripts/
│   ├── install-consul.sh        # Helm install with safety checks
│   ├── deploy-all.sh            # Build images, create secret, apply manifests
│   └── teardown.sh              # Remove apps (keeps Consul)
├── README.md                    # This file
├── QUICKSTART.md                # End-to-end run guide
├── K8S.md                       # Docker Desktop + Consul prerequisites
├── CONSUL_NOTES.md              # Istio → Consul concept map & reference
└── TODO.md                      # Step-by-step build progress tracker
```

---

## Build Progress

| Step | Description | Status |
|------|-------------|--------|
| 1 | Repo scaffold — all directories and empty files | ✅ Done |
| 2 | `consul/helm-values.yaml` + `scripts/install-consul.sh` | ✅ Done |
| 3 | `api-server` application code (Express, CockroachDB) | ✅ Done |
| 4 | `api-server` Kubernetes manifests | ✅ Done |
| 5 | `ui-app` application code (static server + proxy) | ✅ Done |
| 6 | `ui-app` Kubernetes manifests + ServiceIntentions | ✅ Done |
| 7 | Consul mesh config entries (ProxyDefaults, Router, Resolver, Ingress) | ✅ Done |
| 8 | `deploy-all.sh` + `teardown.sh` | ✅ Done |
| 9 | `CONSUL_NOTES.md` — Istio → Consul reference guide | ✅ Done |
| — | `.env.example`, `.gitignore`, `.env` loading in deploy script | ✅ Done |
| — | CockroachDB `verify-full` TLS — CA cert as k8s Secret | ✅ Done |

---

## Quick Start (Once All Steps Complete)

See [QUICKSTART.md](./QUICKSTART.md) for the full walkthrough. Short version:

```bash
# 1. Prerequisites — see K8S.md

# 2. Download the CockroachDB CA certificate (one-time, per machine)
curl --create-dirs -o $HOME/.postgresql/root.crt \
  'https://cockroachlabs.cloud/clusters/<your-cluster-id>/cert'

# 3. Configure your environment
cp .env.example .env
# Edit .env — fill in DB_HOST, DB_PASSWORD, and confirm DB_SSL_CERT_PATH

# 4. Install Consul
./scripts/install-consul.sh

# 5. Build images and deploy (reads .env automatically)
./scripts/deploy-all.sh

# 6. Open the UI
kubectl port-forward svc/consul-ui -n consul 8500:80   # Consul UI
# App UI is available via the IngressGateway LoadBalancer on localhost:8080
```

---

## Key Consul Concepts Demonstrated

| Consul Primitive | Replaces (Istio) | Used In |
|-----------------|------------------|---------|
| Connect Inject (Envoy sidecar) | Sidecar injection | All pods |
| ServiceIntentions | `AuthorizationPolicy` | `ui-app/k8s/serviceintentions.yaml` |
| ServiceDefaults (protocol: http) | `DestinationRule` protocol | `api-server/k8s/servicedefaults.yaml` |
| ProxyDefaults (mTLS strict) | `PeerAuthentication` (STRICT) | `consul/proxydefaults.yaml` |
| ServiceRouter | `VirtualService` (route rules) | `consul/servicerouter.yaml` |
| ServiceResolver | `DestinationRule` (load balancing) | `consul/serviceresolver.yaml` |
| IngressGateway | `Gateway` + `VirtualService` | `consul/ingressgateway.yaml` |

For a detailed explanation of each, see [CONSUL_NOTES.md](./CONSUL_NOTES.md) (written in Step 9).

---

## Prerequisites

- Docker Desktop with Kubernetes enabled
- `kubectl` pointing to `docker-desktop` context
- Helm 3
- Consul CLI (optional, for debugging)
- A CockroachDB Cloud cluster (free tier works)

See [K8S.md](./K8S.md) for detailed setup instructions.

---

## Secrets Management

This project uses a `.env` file (git-ignored) to hold all credentials. A template is provided:

```bash
cp .env.example .env
```

Key variables:

| Variable | Description |
|----------|-------------|
| `DB_HOST` | CockroachDB cluster hostname (no port) |
| `DB_NAME` | Database name (default: `defaultdb`) |
| `DB_USER` | SQL username |
| `DB_PASSWORD` | SQL password |
| `DB_SSL` | Set to `true` for CockroachDB Cloud |
| `DB_SSL_CERT_PATH` | Path to CA cert (default: `~/.postgresql/root.crt`) |
| `KUBE_CONTEXT` | kubectl context guard (default: `docker-desktop`) |
| `API_SERVER_IMAGE` | Docker image tag for api-server |
| `UI_APP_IMAGE` | Docker image tag for ui-app |

`deploy-all.sh` creates two k8s Secrets automatically:
- **`cockroachdb-secret`** — DB host, name, user, password (referenced by env vars in the pod)
- **`cockroachdb-ca-cert`** — CA certificate file, mounted at `/etc/ssl/cockroachdb/root.crt` in the api-server pod

The `pg` driver is configured with `sslmode: verify-full` using the mounted cert, matching the CockroachDB Cloud connection string:
```
postgresql://user:pass@host:26257/defaultdb?sslmode=verify-full
```

---

## Session Management

This project was built incrementally across sessions. [TODO.md](./TODO.md) tracks every step with status and the exact prompt needed to resume — use the `/loadcontext` Copilot prompt to restore state in a new session.
