# QUICKSTART — consul-mesh-poc

A step-by-step guide to get the full POC running from a clean machine.

---

## Prerequisites

Before running any scripts, complete the prerequisites described in [K8S.md](./K8S.md):
- Docker Desktop installed with Kubernetes enabled
- `kubectl` configured to target `docker-desktop` context
- Helm 3 installed
- Consul CLI installed (optional but recommended for debugging)

---

## 1. Clone / Open the Project

```bash
cd consul-mesh-poc
```

---

## 2. Install Consul onto the Cluster

```bash
chmod +x scripts/install-consul.sh
./scripts/install-consul.sh
```

Wait until all Consul pods are Running:

```bash
kubectl get pods -n consul
```

Then open the Consul UI using the port-forward command printed at the end of the install script.

---

## 3. Set Your CockroachDB Credentials

Copy the example env file and fill in your CockroachDB Cloud values:

```bash
cp .env.example .env
# Edit .env and set: DB_HOST, DB_NAME, DB_USER, DB_PASSWORD, DB_SSL_CERT_PATH
```

`deploy-all.sh` will source `.env` automatically and create two Kubernetes Secrets:
- `cockroachdb-secret` — connection credentials
- `cockroachdb-ca-cert` — CA certificate for TLS verification

If you prefer not to use `.env`, export the variables directly:

```bash
export DB_HOST="<host>.cockroachlabs.cloud"
export DB_PASSWORD="<password>"
# DB_NAME defaults to "defaultdb", DB_USER defaults to "root"
```

---

## 4. Deploy Both Services

```bash
chmod +x scripts/deploy-all.sh
./scripts/deploy-all.sh
```

This script will:
1. Build `api-server:latest` and `ui-app:latest` Docker images
2. Create the `cockroachdb-ca-cert` and `cockroachdb-secret` Kubernetes Secrets
3. Apply all Consul mesh config entries (proxydefaults, serviceresolver, servicerouter, ingressgateway)
4. Apply all Kubernetes manifests for `api-server` and `ui-app`
5. Wait for both deployments to roll out

> **Database schema**: The `api-server` automatically runs `CREATE TABLE IF NOT EXISTS items` on startup — no manual schema setup required.

---

## 5. Access the UI

On Docker Desktop the Consul IngressGateway LoadBalancer is exposed directly on `localhost`. Open:

[http://localhost:8080](http://localhost:8080)

> Port-forward is **not** needed on Docker Desktop. If you are on a non-Docker-Desktop cluster, use:
> ```bash
> kubectl port-forward svc/consul-ingress-gateway -n consul 8080:8080
> ```

---

## 6. Verify the Mesh

```bash
# Check all pods have 2/2 containers (app + Envoy sidecar)
kubectl get pods

# Check Consul service catalog
kubectl exec -it <consul-server-pod> -n consul -- consul catalog services

# Tail api-server logs
kubectl logs -l app=api-server -c api-server -f
```

---

## 7. Teardown (Apps Only — Keeps Consul)

```bash
chmod +x scripts/teardown.sh
./scripts/teardown.sh
```

---

## 8. Uninstall Consul (Full Cleanup)

```bash
helm uninstall consul -n consul
kubectl delete namespace consul
```
