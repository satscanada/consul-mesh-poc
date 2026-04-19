# K8S.md — Kubernetes Setup on Docker Desktop + Consul Install

Complete prerequisite guide. Do this **before** running any project scripts.

---

## 1. Install Docker Desktop

Download from: https://www.docker.com/products/docker-desktop/

Supported versions: Docker Desktop 4.x or later (macOS, Windows, Linux).

---

## 2. Enable Kubernetes in Docker Desktop

1. Open **Docker Desktop → Settings (gear icon)**
2. Navigate to **Kubernetes**
3. Check **"Enable Kubernetes"**
4. Click **"Apply & Restart"**
5. Wait for the green Kubernetes indicator in the bottom-left of Docker Desktop

Verify:

```bash
kubectl config current-context
# Expected output: docker-desktop

kubectl get nodes
# Expected: one node named "docker-desktop" in Ready state
```

---

## 3. Install kubectl

macOS (Homebrew):

```bash
brew install kubectl
```

Verify:

```bash
kubectl version --client
```

---

## 4. Install Helm 3

macOS (Homebrew):

```bash
brew install helm
helm version
# Expected: version.BuildInfo{Version:"v3.x.x", ...}
```

---

## 5. Install Consul CLI (Optional — for debugging)

macOS (Homebrew):

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/consul
consul version
```

The CLI is not required to run the POC but is very useful for querying the catalog, checking intentions, and reading config entries.

---

## 6. Verify Resource Allocation

Consul + two services require reasonable resources. In Docker Desktop Settings → Resources, set at minimum:

| Resource | Recommended |
|----------|-------------|
| CPUs     | 4           |
| Memory   | 6 GB        |
| Swap     | 1 GB        |

---

## 7. Install Consul via Helm

> This is automated by `scripts/install-consul.sh`. Run that script instead of doing this manually. The steps below are for reference.

```bash
# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Create consul namespace
kubectl create namespace consul

# Install using project values
helm install consul hashicorp/consul \
  --namespace consul \
  --values consul/helm-values.yaml \
  --wait
```

Check pod status:

```bash
kubectl get pods -n consul
```

All pods should reach `Running` / `Completed` state. Typical pods:
- `consul-server-0` — Consul server
- `consul-client-xxxxx` — Consul client DaemonSet (one per node)
- `consul-connect-injector-xxxxx` — Sidecar injector webhook
- `consul-controller-xxxxx` — Config entry controller
- `consul-ingress-gateway-xxxxx` — IngressGateway

---

## 8. Access the Consul UI

```bash
kubectl port-forward svc/consul-ui -n consul 8500:80
```

Open: [http://localhost:8500](http://localhost:8500)

---

## 9. Troubleshooting Kubernetes Setup

```bash
# Is Kubernetes running?
kubectl cluster-info

# Are system pods healthy?
kubectl get pods -n kube-system

# Reset Kubernetes (Docker Desktop)
# Docker Desktop → Settings → Kubernetes → Reset Kubernetes Cluster

# Force re-apply context
kubectl config use-context docker-desktop
```

---

## 10. Consul Version Compatibility

This POC targets:

| Component       | Version       |
|----------------|---------------|
| Consul OSS     | 1.17.x or later |
| Consul Helm    | 1.3.x or later  |
| Kubernetes     | 1.27+           |
| Helm           | 3.x             |

> The `consul.hashicorp.com/v1alpha1` CRD API version is used for all config entries (ServiceDefaults, ServiceIntentions, ServiceRouter, ServiceResolver, IngressGateway, ProxyDefaults). This is stable as of Consul 1.12+.
