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

## 3. Set Your CockroachDB Connection String

Export the connection string from CockroachDB Cloud before deploying:

```bash
export DATABASE_URL="postgresql://<user>:<password>@<host>:<port>/<database>?sslmode=verify-full"
```

> Source: **shell environment variable** — consumed by `scripts/deploy-all.sh` which creates the `cockroachdb-secret` Kubernetes Secret.

---

## 4. Deploy Both Services

```bash
chmod +x scripts/deploy-all.sh
./scripts/deploy-all.sh
```

This script will:
1. Build `api-server:local` and `ui-app:local` Docker images
2. Create the `cockroachdb-secret` from `$DATABASE_URL`
3. Apply all Kubernetes manifests for `api-server` and `ui-app`
4. Apply all Consul config entries
5. Print pod status

---

## 5. Access the UI

Port-forward the Consul IngressGateway to reach the ui-app:

```bash
kubectl port-forward svc/consul-ingress-gateway -n consul 8080:8080
```

Then open: [http://localhost:8080](http://localhost:8080)

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
