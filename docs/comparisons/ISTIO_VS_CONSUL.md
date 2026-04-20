# Istio vs Consul Service Mesh — Side-by-Side Comparison

> Grounded in the **consul-mesh-poc** implementation: a two-service app (`ui-app` → `api-server` → CockroachDB)
> deployed on Docker Desktop Kubernetes with every feature mapped to its Istio equivalent.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Sidecar Injection](#2-sidecar-injection)
3. [Mutual TLS (mTLS)](#3-mutual-tls-mtls)
4. [Access Control / Authorization](#4-access-control--authorization)
5. [Protocol Declaration](#5-protocol-declaration)
6. [Service Subsets & Load Balancing](#6-service-subsets--load-balancing)
7. [L7 Traffic Routing](#7-l7-traffic-routing)
8. [Ingress](#8-ingress)
9. [Upstream Discovery](#9-upstream-discovery)
10. [Observability & Metrics](#10-observability--metrics)
11. [Installation](#11-installation)
12. [Mental Model Differences](#12-mental-model-differences)
13. [Feature Parity Summary](#13-feature-parity-summary)

---

## 1. Architecture Overview

Both meshes use the **Envoy proxy** as the data plane. The control plane is what differs.

```
┌─────────────────────────────────────────────────────────────────────┐
│  ISTIO                          │  CONSUL                           │
│                                 │                                   │
│  istiod (Pilot + Citadel +      │  consul-server (catalog, CA,      │
│    Galley merged)               │    KV, ACL, intentions)           │
│      │                          │      │                            │
│      │ xDS (gRPC)               │      │ xDS (gRPC)                 │
│      ▼                          │      ▼                            │
│  [envoy sidecar]                │  [envoy sidecar]                  │
│  injected by MutatingWebhook    │  injected by consul-k8s webhook   │
└─────────────────────────────────────────────────────────────────────┘
```

**Key difference:** Consul's control plane is the **Consul agent/server itself** — the same
component used for service discovery, KV, and DNS outside of Kubernetes. Istio is
Kubernetes-only.

---

## 2. Sidecar Injection

### Istio approach
Enable injection at the **namespace** level; all pods in that namespace get sidecars automatically.

```yaml
# Label the namespace once
kubectl label namespace default istio-injection=enabled

# Pod needs no annotation — injection is automatic
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
spec:
  template:
    metadata:
      labels:
        app: api-server
    # No annotation needed
```

### Consul approach (this project)
Injection is opt-in **per pod** via annotation. No namespace label needed.

```yaml
# api-server/k8s/deployment.yaml
template:
  metadata:
    annotations:
      consul.hashicorp.com/connect-inject: "true"   # ← explicit per pod
```

```yaml
# ui-app/k8s/deployment.yaml
template:
  metadata:
    annotations:
      consul.hashicorp.com/connect-inject: "true"
      consul.hashicorp.com/connect-service-upstreams: "api-server:3000"
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Granularity | Namespace-wide (default) | Per-pod annotation |
| Opt-out | `sidecar.istio.io/inject: "false"` | Simply omit the annotation |
| Upstream declaration | Not required (transparent proxy always on) | Required annotation OR transparent proxy mode |

---

## 3. Mutual TLS (mTLS)

### Istio approach
Configured via two CRDs: `PeerAuthentication` (what the server accepts) and
`DestinationRule` (what the client sends).

```yaml
# Mesh-wide strict mTLS — Istio
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system   # mesh-wide when in root namespace
spec:
  mtls:
    mode: STRICT

---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: default
  namespace: istio-system
spec:
  host: "*.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
```

### Consul approach (this project)
mTLS is **on by default** once `connectInject` is enabled. The `ProxyDefaults` global entry
controls mesh-wide proxy behaviour.

```yaml
# consul/proxydefaults.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ProxyDefaults
metadata:
  name: global          # must be "global" — singleton
  namespace: default
spec:
  meshGateway:
    mode: local
  transparentProxy: {}
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Default state | PERMISSIVE (accepts both plain + mTLS) | mTLS enforced as soon as inject is on |
| Configuration | Two CRDs (`PeerAuthentication` + `DestinationRule`) | Zero config — or one `ProxyDefaults` for global options |
| Certificate Authority | Istiod built-in CA (or external) | Consul built-in CA (or Vault) |
| Per-service override | `PeerAuthentication` per namespace/service | Not directly supported at service level in OSS |

---

## 4. Access Control / Authorization

This is the **biggest conceptual difference** between the two meshes.

### Istio approach
Default is **allow-all**. You add `AuthorizationPolicy` to restrict traffic.

```yaml
# Istio — allow only ui-app → api-server
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: api-server-allow-ui
  namespace: default
spec:
  selector:
    matchLabels:
      app: api-server
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/default/sa/ui-app"

---
# Explicit deny-all (must be added separately)
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: default
spec:
  {}   # empty spec = deny all
```

### Consul approach (this project)
Default is **deny-all** once intentions are enabled. You add allows explicitly.

```yaml
# ui-app/k8s/serviceintentions.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceIntentions
metadata:
  name: api-server
  namespace: default
spec:
  destination:
    name: api-server
  sources:
    - name: ui-app
      action: allow   # ← only allowed caller
    - name: "*"
      action: deny    # ← explicit catch-all (redundant but clear)
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Default stance | Allow-all | Deny-all |
| Identity basis | SPIFFE/X.509 service account | Consul service name (SPIFFE under the hood) |
| Rule location | `AuthorizationPolicy` on the *destination* | `ServiceIntentions` on the *destination* |
| L7 rules (path/method) | `AuthorizationPolicy` `.rules[].to.operation` | `ServiceIntentions` `.sources[].permissions` |
| Namespace scoping | `.metadata.namespace` + `from[].source.namespaces` | `.spec.sources[].namespace` (requires namespaces feature) |

---

## 5. Protocol Declaration

### Istio approach
Istio auto-detects protocols by sniffing traffic, or you declare it in a `Service` port name
(`http-`, `grpc-`, `tcp-` prefix) or `DestinationRule`.

```yaml
# Istio — protocol via Service port name convention
apiVersion: v1
kind: Service
metadata:
  name: api-server
spec:
  ports:
    - name: http   # "http" prefix → Istio treats as HTTP
      port: 3000
```

```yaml
# Or explicitly via DestinationRule
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: api-server
spec:
  host: api-server
  trafficPolicy:
    connectionPool:
      http:
        h2UpgradePolicy: UPGRADE
```

### Consul approach (this project)
Must be declared explicitly via `ServiceDefaults`. Without it, the proxy operates at L4 only
and L7 features (routing, splitting, timeouts) are unavailable.

```yaml
# api-server/k8s/servicedefaults.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: api-server
  namespace: default
spec:
  protocol: http   # enables L7 — required for ServiceRouter/ServiceResolver
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Auto-detection | Yes (protocol sniffing) | No — must declare explicitly |
| Declaration method | Service port name prefix or DestinationRule | `ServiceDefaults.spec.protocol` |
| Without declaration | Falls back to L4 (still works) | Falls back to L4 (L7 features silently unavailable) |

---

## 6. Service Subsets & Load Balancing

### Istio approach
Subsets are defined inside `DestinationRule` alongside load balancing policy.

```yaml
# Istio — define subsets + load balancing
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: api-server
spec:
  host: api-server
  trafficPolicy:
    connectionPool:
      tcp:
        connectTimeout: 5s
    loadBalancer:
      simple: ROUND_ROBIN
  subsets:
    - name: stable
      labels:
        version: stable
```

### Consul approach (this project)
Subsets are defined in `ServiceResolver`. Health-check filtering (`onlyPassing`) replaces
label selectors.

```yaml
# consul/serviceresolver.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceResolver
metadata:
  name: api-server
  namespace: default
spec:
  connectTimeout: 5s
  defaultSubset: stable
  subsets:
    stable:
      onlyPassing: true   # only route to healthy instances
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Where subsets live | `DestinationRule` | `ServiceResolver` |
| Subset filtering | Pod label selectors | Health check status (`onlyPassing`) or metadata filters |
| Failover | `DestinationRule.trafficPolicy.outlierDetection` | `ServiceResolver.failover` (cross-DC supported) |
| Load balancing algorithm | `DestinationRule.trafficPolicy.loadBalancer` | `ServiceResolver.loadBalancer` (Consul 1.9+) |
| Connect timeout | `DestinationRule.trafficPolicy.connectionPool` | `ServiceResolver.connectTimeout` |

---

## 7. L7 Traffic Routing

### Istio approach
`VirtualService` handles both routing rules **and** traffic destination in a single resource.

```yaml
# Istio — route /api/ traffic with timeout
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: api-server
spec:
  hosts:
    - api-server
  http:
    - match:
        - uri:
            prefix: /api/
      route:
        - destination:
            host: api-server
            subset: stable
      timeout: 10s
```

### Consul approach (this project)
Routing and destination resolution are **separate CRDs**: `ServiceRouter` matches and
dispatches; `ServiceResolver` defines what the subset means.

```yaml
# consul/servicerouter.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceRouter
metadata:
  name: api-server
  namespace: default
spec:
  routes:
    - match:
        http:
          pathPrefix: /api/
      destination:
        service: api-server
        serviceSubset: stable   # references ServiceResolver subset
        requestTimeout: 10s
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Routing resource | `VirtualService` | `ServiceRouter` |
| Subset definition | Same `DestinationRule` | Separate `ServiceResolver` |
| Traffic splitting | `VirtualService.http[].route[].weight` | `ServiceSplitter` (separate CRD) |
| Header manipulation | `VirtualService.http[].headers` | `ServiceRouter.routes[].destination.requestHeaders` |
| Retries | `VirtualService.http[].retries` | `ServiceRouter.routes[].destination` (Consul 1.14+) |
| Fault injection | `VirtualService.http[].fault` | Not natively supported in Consul OSS |

---

## 8. Ingress

### Istio approach
Two CRDs work together: `Gateway` (binds a port/TLS on the ingress pod) and `VirtualService`
(routes to a backend).

```yaml
# Istio — Gateway + VirtualService for ingress
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: main-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*"

---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: ui-app
spec:
  hosts:
    - "*"
  gateways:
    - main-gateway
  http:
    - route:
        - destination:
            host: ui-app
            port:
              number: 4000
```

### Consul approach (this project)
A single `IngressGateway` CRD declares both the listener and the backend service.
The gateway pod is deployed by the Helm chart.

```yaml
# consul/ingressgateway.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: IngressGateway
metadata:
  name: ingress-gateway
  namespace: default
spec:
  listeners:
    - port: 8080
      protocol: http
      services:
        - name: ui-app
          hosts:
            - "*"
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Resources required | 2 (`Gateway` + `VirtualService`) | 1 (`IngressGateway`) |
| TLS termination | `Gateway.spec.servers[].tls` | `IngressGateway.spec.tls` |
| Path-based routing at ingress | `VirtualService.http[].match` | Requires `ServiceRouter` behind the gateway |
| Gateway pod | `istio-ingressgateway` (separate Deployment) | `consul-ingress-gateway` (Helm-managed) |
| Multiple listeners | Multiple `Gateway` server entries | Multiple `IngressGateway` listener entries |

---

## 9. Upstream Discovery

### Istio approach
Transparent proxy is **always on**. Envoy intercepts all outbound traffic via iptables and
routes it based on service name. No annotation needed in application code.

```yaml
# Istio pod — no upstream annotation needed
# server.js can just call http://api-server:3000 directly
```

### Consul approach (this project)
Two modes available:

**Mode A — Explicit upstream annotation (used in this project):**
```yaml
# ui-app/k8s/deployment.yaml
annotations:
  consul.hashicorp.com/connect-inject: "true"
  consul.hashicorp.com/connect-service-upstreams: "api-server:3000"
  # Envoy opens localhost:3000 → api-server mesh traffic
```
`server.js` then uses `API_URL=http://localhost:3000` (not `http://api-server:3000`).

**Mode B — Transparent proxy (Consul 1.10+, not used in this project):**
```yaml
annotations:
  consul.hashicorp.com/connect-inject: "true"
  consul.hashicorp.com/transparent-proxy: "true"
  # Now http://api-server:3000 works directly, like Istio
```

### Differences

| | Istio | Consul (explicit upstream) | Consul (transparent proxy) |
|---|---|---|---|
| App code change needed | No | Yes — use `localhost:<port>` | No |
| iptables interception | Yes (always) | No | Yes |
| Service URL in code | `http://api-server:3000` | `http://localhost:3000` | `http://api-server:3000` |

---

## 10. Observability & Metrics

### Istio approach
Prometheus metrics, Jaeger/Zipkin tracing, and Kiali topology are first-class features
built into the Istio add-on stack. Enabled by default in most installs.

```yaml
# Istio telemetry (auto-enabled)
# - Prometheus scrapes istio-proxy metrics
# - Jaeger receives trace spans automatically
# - Kiali shows the service graph
```

### Consul approach (this project)
Metrics are enabled in `helm-values.yaml` and scraped by Prometheus. Tracing requires
additional Envoy config. No built-in topology UI (Consul UI shows service catalogue only).

```yaml
# consul/helm-values.yaml (already written in Step 2)
global:
  metrics:
    enabled: true
    enableAgentMetrics: true
    agentMetricsRetentionTime: "1m"
    enableHostMetrics: true
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Prometheus metrics | Auto-enabled | Enabled via Helm values |
| Distributed tracing | Auto (Zipkin/Jaeger headers propagated) | Manual Envoy config required |
| Service topology UI | Kiali (built-in add-on) | Consul UI (service catalogue only) |
| Access logs | `MeshConfig.accessLogFile` | `ProxyDefaults.config` Envoy JSON |

---

## 11. Installation

### Istio
```bash
# Istio — istioctl or Helm
istioctl install --set profile=default

# Or via Helm
helm install istio-base istio/base -n istio-system
helm install istiod istio/istiod -n istio-system
helm install istio-ingressgateway istio/gateway -n istio-system
```

### Consul (this project — `scripts/install-consul.sh`)
```bash
# Single Helm chart covers everything
helm repo add hashicorp https://helm.releases.hashicorp.com
helm upgrade --install consul hashicorp/consul \
  --namespace consul \
  --values consul/helm-values.yaml \
  --wait
```

### Differences

| | Istio | Consul (this project) |
|---|---|---|
| Charts | 3 separate charts | 1 chart |
| CRD installation | Separate base chart | Bundled in main chart |
| Control plane pods | istiod, ingressgateway | consul-server, consul-client (DaemonSet), consul-connect-injector |
| Install script | `istioctl` or manual Helm | `scripts/install-consul.sh` |

---

## 12. Mental Model Differences

| Concept | Istio Mental Model | Consul Mental Model |
|---------|-------------------|---------------------|
| Default security | Allow-all, add restrictions | Deny-all, add allowances |
| Protocol awareness | Auto-detect (sniff or port name) | Explicit declaration required |
| Upstream wiring | Transparent — just use service DNS | Explicit upstream annotation (or opt-in transparent proxy) |
| Routing + destination | Single `VirtualService` | Split: `ServiceRouter` (rules) + `ServiceResolver` (destinations) |
| Traffic splitting | Same `VirtualService` | Separate `ServiceSplitter` CRD |
| Global config | `MeshConfig` | `ProxyDefaults` singleton |
| Ingress | `Gateway` + `VirtualService` (two CRDs) | `IngressGateway` (one CRD) |
| Non-K8s services | `ServiceEntry` | `TerminatingGateway` |
| Cross-cluster | `ServiceEntry` + multi-cluster Istio | `MeshGateway` + WAN federation |

---

## 13. Feature Parity Summary

Every feature used in **consul-mesh-poc** and its Istio equivalent:

| Feature | consul-mesh-poc file | Consul CRD | Istio Equivalent |
|---------|---------------------|------------|-----------------|
| Sidecar injection | `api-server/k8s/deployment.yaml` | Pod annotation | Namespace label |
| Upstream wiring | `ui-app/k8s/deployment.yaml` | `connect-service-upstreams` annotation | Transparent proxy (automatic) |
| Global proxy config | `consul/proxydefaults.yaml` | `ProxyDefaults` | `MeshConfig` |
| mTLS enforcement | `consul/proxydefaults.yaml` | `ProxyDefaults` (on by default) | `PeerAuthentication` STRICT |
| Protocol declaration | `api-server/k8s/servicedefaults.yaml` | `ServiceDefaults` | Service port name / `DestinationRule` |
| Access control | `ui-app/k8s/serviceintentions.yaml` | `ServiceIntentions` | `AuthorizationPolicy` |
| Service subsets | `consul/serviceresolver.yaml` | `ServiceResolver` | `DestinationRule` subsets |
| L7 path routing + timeout | `consul/servicerouter.yaml` | `ServiceRouter` | `VirtualService` |
| Ingress gateway | `consul/ingressgateway.yaml` | `IngressGateway` | `Gateway` + `VirtualService` |
| Metrics | `consul/helm-values.yaml` | Helm values | Prometheus add-on (auto) |
| Install script | `scripts/install-consul.sh` | Helm chart | `istioctl install` |
| Deploy pipeline | `scripts/deploy-all.sh` | Shell script | Shell script |
