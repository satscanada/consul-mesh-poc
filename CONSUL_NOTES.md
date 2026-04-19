# CONSUL_NOTES.md — Istio → Consul Concept Map & Reference

> A concise study guide for engineers familiar with Istio moving to Consul Service Mesh on Kubernetes.

---

## 1. Concept Mapping

| Istio Primitive | Consul Equivalent | Notes |
|-----------------|-------------------|-------|
| Sidecar injection (`istio-injection: enabled`) | `consul.hashicorp.com/connect-inject: "true"` annotation | Per-pod annotation in Consul; namespace-level in Istio |
| `PeerAuthentication` (STRICT mTLS) | `ProxyDefaults` global config entry | Consul enforces mTLS by default once inject is on |
| `AuthorizationPolicy` | `ServiceIntentions` | Consul defaults to **deny-all** when intentions are enabled |
| `DestinationRule` (TLS mode, subsets) | `ServiceDefaults` + `ServiceResolver` | `ServiceDefaults` sets protocol; `ServiceResolver` defines subsets |
| `VirtualService` (routing rules) | `ServiceRouter` | L7 path/header/method matching |
| `VirtualService` (traffic shifting) | `ServiceSplitter` | Weight-based splits between subsets |
| `Gateway` + `VirtualService` (ingress) | `IngressGateway` config entry + Helm `ingressGateways` | Consul ingress is a first-class Helm component |
| `EnvoyFilter` | `EnvoyExtensions` (Consul 1.16+) | Used sparingly; prefer native config entries |
| `ServiceEntry` (external services) | `ServiceDefaults` with `ExternalSNI` or `TerminatingGateway` | Terminating gateways proxy traffic to external services |
| Mesh-wide mTLS (`MeshConfig`) | `ProxyDefaults` (`name: global`) | Single global singleton CRD |

---

## 2. Key Differences from Istio

### 2.1 Intentions = Deny-All by Default
Once the Consul helm chart has `connectInject.enabled: true`, any service without a matching
`ServiceIntentions` entry will have its traffic **denied**. This is the opposite of Istio's
default-allow model.

```yaml
# Allow ui-app → api-server, deny everyone else
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceIntentions
metadata:
  name: api-server
spec:
  destination:
    name: api-server
  sources:
    - name: ui-app
      action: allow
    - name: "*"
      action: deny
```

### 2.2 Protocol Must Be Declared
Consul proxies operate at L4 by default. To use L7 features (routing, splitting, retries),
you **must** declare the protocol via `ServiceDefaults`:

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: api-server
spec:
  protocol: http   # or grpc, http2, tcp
```

### 2.3 Upstream Annotation vs Istio Auto-Discovery
Istio discovers all services automatically. In Consul, the sidecar must be told which
upstreams to open local ports for:

```yaml
annotations:
  consul.hashicorp.com/connect-inject: "true"
  consul.hashicorp.com/connect-service-upstreams: "api-server:3000"
```
This exposes `api-server` on `localhost:3000` inside the calling pod.
Transparent proxy mode (Consul 1.10+) can remove this requirement.

### 2.4 CRD Hierarchy for L7 Traffic Management
The full chain required for L7 routing:

```
ServiceDefaults (protocol: http)
    └── ServiceResolver  (define subsets / failover)
            └── ServiceRouter  (path/header matching → subset)
                    └── ServiceSplitter (traffic %)
```
You only need the levels you actually use.

---

## 3. Helm Chart Key Values

```yaml
global:
  tls:
    enabled: true          # mTLS between agents
    enableAutoEncrypt: true # clients get certs automatically

connectInject:
  enabled: true            # enables the mutating webhook
  default: false           # require explicit opt-in per pod

controller:
  enabled: true            # enables the CRD controller (applies config entries)

ingressGateways:
  enabled: true
  defaults:
    service:
      type: LoadBalancer   # exposes on localhost on Docker Desktop
```

---

## 4. Useful kubectl / consul CLI Commands

```bash
# Check which pods have the Envoy sidecar
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'

# View registered services in Consul catalog
kubectl exec -n consul deploy/consul-server -- consul catalog services

# List all service intentions
kubectl get serviceintentions

# Check config entry sync status
kubectl get servicedefaults,servicerouter,serviceresolver,proxydefaults

# Port-forward the Consul UI
kubectl port-forward svc/consul-ui -n consul 8500:80

# Tail Envoy access logs for a specific pod
kubectl logs <pod-name> -c envoy-sidecar -f

# Check mTLS certificate for a service
kubectl exec -n consul deploy/consul-server -- \
  consul connect ca get-config
```

---

## 5. Debugging Checklist

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `connection refused` from sidecar | No matching Intention | Add `ServiceIntentions` allow rule |
| L7 routing not working | Protocol not set | Add `ServiceDefaults` with `protocol: http` |
| Upstream not reachable | Missing upstream annotation | Add `connect-service-upstreams` annotation |
| Config entry not applied | Controller not enabled | Set `controller.enabled: true` in Helm values |
| Pod fails readiness | Sidecar not injected | Check `connectInject` webhook is running; verify annotation |
| Ingress returns 503 | Service not registered or no intention | Check catalog + add intention for ingress → service |

---

## 6. Deep Dive — Every Config File in This Project

This section walks through every Consul-related YAML in the repo, explaining *what* each field does,
*why* it is needed, and *what breaks* if you remove it.

---

### 6.1 `consul/helm-values.yaml` — Helm Chart Configuration

This file is the single source of truth for how the Consul control plane is installed on the cluster.
It is consumed by `scripts/install-consul.sh` via `helm install consul hashicorp/consul -f consul/helm-values.yaml`.

#### `global` block

```yaml
global:
  name: consul
  datacenter: dc1
```
`name` becomes the prefix for every Kubernetes resource Helm creates (e.g. `consul-server`, `consul-client`).
`datacenter` is the logical name Consul uses for federation. All services registered here will report
themselves as belonging to `dc1`. This matters if you ever add WAN federation or Consul Peering.

#### `global.tls`

```yaml
tls:
  enabled: true
  enableAutoEncrypt: true
  verify: true
  httpsOnly: false
```

| Field | Effect |
|-------|--------|
| `enabled: true` | All Consul **agent RPC** traffic (server↔client↔sidecar) is encrypted with TLS. Without this, a compromised node could eavesdrop on catalog data. |
| `enableAutoEncrypt: true` | Clients bootstrap their own TLS certificates from the server automatically — you do not need to distribute certs manually. |
| `verify: true` | Mutual TLS for agent-to-agent connections: both sides present certificates. |
| `httpsOnly: false` | Leaves HTTP health-check endpoints available internally. Set to `true` in production to enforce HTTPS everywhere. |

> Note: This TLS governs **agent RPC** (gossip, catalog). Service-to-service mTLS inside the mesh is
> controlled separately by `ProxyDefaults` (see §6.2).

#### `global.metrics`

```yaml
metrics:
  enabled: true
  enableAgentMetrics: true
  agentMetricsRetentionTime: "1m"
  enableHostMetrics: true
```

Enables Prometheus-format metrics scraped from both the Consul agents and each Envoy sidecar.
`agentMetricsRetentionTime: "1m"` is intentionally short for local dev — extend to `"10m"` in staging.
`enableHostMetrics: true` adds node-level CPU/memory metrics to the Consul UI.

#### `server` block

```yaml
server:
  replicas: 1
  bootstrapExpect: 1
  disruptionBudget:
    enabled: false
```

`replicas: 1` + `bootstrapExpect: 1` — a single-server Raft cluster. This is fine for local dev but
**not HA**. Production should use 3 or 5 replicas with `bootstrapExpect` matching.
`disruptionBudget.enabled: false` — the default PodDisruptionBudget blocks rolling restarts when only
one replica exists. Disabling it allows `kubectl rollout restart` to work on a single-node cluster.

#### `connectInject` block

```yaml
connectInject:
  enabled: true
  default: false
  metrics:
    defaultEnabled: true
    defaultEnableMerging: false
```

| Field | Effect |
|-------|--------|
| `enabled: true` | Installs the mutating admission webhook that intercepts pod creation and injects the Envoy sidecar + init container. |
| `default: false` | Injection is **opt-in**. Pods must carry the annotation `consul.hashicorp.com/connect-inject: "true"` to get a sidecar. Setting this to `true` would inject sidecars into *every* pod including system pods — dangerous. |
| `metrics.defaultEnabled: true` | Each injected Envoy exposes metrics at `:20200/metrics`. |
| `defaultEnableMerging: false` | Keeps app and Envoy metrics on separate ports. Set to `true` only if your scraper expects a single merged endpoint. |

#### `controller` block

```yaml
controller:
  enabled: true
```

The controller is a Kubernetes operator that watches for Consul CRD objects (`ServiceDefaults`,
`ServiceIntentions`, `ServiceRouter`, etc.) and syncs them into the Consul catalog as config entries.
**Without this, `kubectl apply -f` on any Consul CRD will create the k8s object but it will never
reach Consul — traffic management and intentions will silently do nothing.**

#### `ui` block

```yaml
ui:
  enabled: true
  service:
    type: ClusterIP
  metrics:
    enabled: true
    provider: prometheus
```

Deploys the Consul web dashboard as a ClusterIP service. Access it with:
```bash
kubectl port-forward svc/consul-ui -n consul 8500:80
```
`metrics.provider: prometheus` wires the UI's built-in metrics graphs to your Prometheus endpoint.

#### `ingressGateways` block

```yaml
ingressGateways:
  enabled: true
  defaults:
    service:
      type: LoadBalancer
```

Creates the Envoy-based ingress gateway deployment and service. On Docker Desktop, `LoadBalancer`
causes the gateway to bind to `localhost:8080` without needing a NodePort or extra configuration.
The port and the services exposed through it are defined separately in `consul/ingressgateway.yaml`.

---

### 6.2 `consul/proxydefaults.yaml` — Global Mesh Policy

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ProxyDefaults
metadata:
  name: global       # must be exactly "global" — Consul only accepts one instance
  namespace: default
spec:
  meshGateway:
    mode: local
  config:
    envoy_extra_static_clusters_json: ""
  transparentProxy: {}
```

`ProxyDefaults` is a **singleton** config entry — there can only be one, and it must be named `global`.
It defines the baseline behaviour for *every* Envoy sidecar in the mesh.

| Field | What it does |
|-------|-------------|
| `meshGateway.mode: local` | When traffic needs to cross datacenters, sidecars prefer the gateway in their own datacenter rather than going direct. Harmless for single-DC setups, required for multi-DC. |
| `config.envoy_extra_static_clusters_json: ""` | Placeholder for injecting raw Envoy bootstrap config. Keeping it empty makes the field explicit and easy to extend later (e.g. to add a custom telemetry cluster). |
| `transparentProxy: {}` | Enables transparent proxy mode globally: the iptables rules redirect *all* inbound/outbound traffic through Envoy automatically, removing the need for `connect-service-upstreams` annotations. The empty `{}` applies the feature with defaults. |

**What happens without this file?**  
Consul will use built-in defaults, which may vary by version. Explicitly applying `ProxyDefaults`
pins the behaviour and makes it visible in the Consul UI under *Config Entries*.

---

### 6.3 `consul/serviceresolver.yaml` — Service Discovery & Health Filtering

```yaml
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
      onlyPassing: true
```

`ServiceResolver` answers the question: *"Given a service name, which instances should receive traffic,
and what are the named groups (subsets) within that service?"*

| Field | What it does |
|-------|-------------|
| `connectTimeout: 5s` | Maximum time Envoy waits to establish a new connection to an upstream instance. After 5 s it returns a 503 to the caller. Tune this based on your app's cold-start time. |
| `defaultSubset: stable` | When a `ServiceRouter` route does not explicitly name a subset, or when direct service discovery is used, traffic goes to the `stable` subset. This prevents untagged traffic from reaching canary/v2 instances. |
| `subsets.stable.onlyPassing: true` | Only instances whose Consul health check is in the *passing* state are included in the `stable` subset. Instances that are *warning* or *critical* (e.g. failing readiness probes) are automatically removed from the load-balancing pool without any manual intervention. |

**Relation to ServiceRouter:** The `ServiceRouter` names `serviceSubset: stable` in its destination.
That name is resolved here. If you remove this file, the router's `stable` subset reference becomes
dangling and Consul will return a 503.

**Relation to blue-green / canary (Steps 10–12):** You will extend this file with additional subsets
(`v1`, `v2`, `canary`) when implementing those demos.

---

### 6.4 `consul/servicerouter.yaml` — L7 Request Routing

```yaml
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
        serviceSubset: stable
        requestTimeout: 10s
```

`ServiceRouter` is Consul's equivalent of an Istio `VirtualService`. It operates at Layer 7 and
inspects HTTP path, headers, and method to decide where a request goes.

| Field | What it does |
|-------|-------------|
| `match.http.pathPrefix: /api/` | Matches any request whose URL starts with `/api/`. This covers `/api/items`, `/api/items/1`, `/api/version`, etc. |
| `destination.service: api-server` | The Consul-registered service name to forward matched requests to. |
| `destination.serviceSubset: stable` | Routes only to the `stable` subset defined in `ServiceResolver`. This is the safety net that prevents traffic from accidentally reaching unhealthy or canary pods. |
| `destination.requestTimeout: 10s` | Envoy enforces this timeout at the proxy layer, independently of any application-level timeout. If the api-server takes longer than 10 s to respond, Envoy returns a 504 Gateway Timeout without waiting for the app. |

**Why is this needed even with a single subset?**  
Without `ServiceRouter`, Consul routes to any healthy instance regardless of path or timeout.
Declaring the router explicitly (a) enforces the timeout, (b) pins traffic to the passing subset,
and (c) gives you a ready-made extension point for the routing rules in Steps 10–12.

**Prerequisite chain:** `ServiceRouter` requires `ServiceDefaults` to declare `protocol: http`.
Without it, Consul treats the service as TCP and the router is ignored entirely.

---

### 6.5 `consul/ingressgateway.yaml` — External Entry Point

```yaml
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

This config entry tells the Consul ingress gateway (the Envoy deployment created by Helm) what to
listen for and where to send traffic.

| Field | What it does |
|-------|-------------|
| `listeners[0].port: 8080` | The gateway listens on port 8080. This must match the port configured in the Helm `ingressGateways.gateways` ports list. The Kubernetes LoadBalancer service exposes this port externally. |
| `listeners[0].protocol: http` | Enables HTTP-level routing at the gateway. Use `tcp` only for non-HTTP protocols. `http` allows host-based routing (the `hosts` field below). |
| `services[0].name: ui-app` | The Consul service name to proxy traffic to. The gateway will resolve this through the Consul catalog and load-balance across healthy ui-app instances. |
| `services[0].hosts: ["*"]` | Wildcard hostname match — any `Host:` header is accepted. In production, replace with your actual domain (e.g. `["app.example.com"]`) to host multiple services on the same gateway port using virtual hosting. |

**Traffic path:** Browser → `localhost:8080` → LoadBalancer Service → Ingress Gateway pod (Envoy)
→ (mTLS) → ui-app Envoy sidecar → ui-app container.

**What breaks without this file?**  
The Helm chart creates the gateway deployment and service but the gateway has no listeners configured.
All traffic to port 8080 results in a connection refused from Envoy.

---

### 6.6 `ui-app/k8s/serviceintentions.yaml` — Zero-Trust Access Control

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceIntentions
metadata:
  name: api-server      # convention: name matches the destination service
  namespace: default
spec:
  destination:
    name: api-server
  sources:
    - name: ui-app
      action: allow
    - name: "*"
      action: deny
```

`ServiceIntentions` is Consul's authorization layer — the equivalent of Istio's `AuthorizationPolicy`.
It answers: *"Which services are allowed to call api-server?"*

**Why this file lives in `ui-app/k8s/`:**  
The intention governs access *to* `api-server`, but it is authored from the perspective of the caller
(`ui-app`). Placing it alongside the ui-app manifests makes it clear that ui-app is the only
authorized caller. This is a team-convention choice; the file could also live in `api-server/k8s/`.

| Field | What it does |
|-------|-------------|
| `destination.name: api-server` | This intention applies to all traffic directed *at* the `api-server` service in the Consul catalog. |
| `sources[0].name: ui-app` + `action: allow` | Explicitly permits mTLS connections that originate from the `ui-app` Envoy sidecar. Consul verifies the source's certificate identity (SPIFFE URI) against this rule. |
| `sources[1].name: "*"` + `action: deny` | Wildcard deny for everything else — any service not explicitly listed is blocked at the Envoy layer before the request reaches the api-server container. This implements a default-deny posture. |

**How enforcement works under the hood:**  
When the `ui-app` sidecar opens a connection to `api-server`, both sidecars present their SPIFFE
`x509` certificates (issued by Consul's built-in CA). The `api-server` sidecar checks the source
SPIFFE URI against the intention rules before allowing the connection. This check happens at the
network layer — the api-server application process *never sees* denied connections.

**What breaks without this file?**  
With `connectInject` enabled, Consul defaults to **deny-all** between services. Without any
`ServiceIntentions`, ui-app's requests to api-server will be silently dropped at the sidecar level
and you will see `connection refused` in the ui-app logs.

---

### 6.7 `api-server/k8s/servicedefaults.yaml` — Protocol Declaration

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceDefaults
metadata:
  name: api-server      # must match the Consul service name exactly
  namespace: default
spec:
  protocol: http
```

`ServiceDefaults` is one of the simplest Consul CRDs, but it unlocks the entire L7 feature set.

| Field | What it does |
|-------|-------------|
| `protocol: http` | Tells Consul (and Envoy) that this service speaks HTTP/1.1. Valid values: `tcp` (default), `http`, `http2`, `grpc`. |

**Why protocol declaration is mandatory for L7 features:**  
By default, Consul treats every service as TCP. At L4, Envoy can only accept or deny connections —
it cannot inspect paths, headers, or methods. Setting `protocol: http` upgrades Envoy's listener to
an HTTP connection manager, which enables:

- `ServiceRouter` — path/header/method-based routing rules
- `ServiceSplitter` — percentage traffic splits (needed for canary and A/B demos)
- `ServiceResolver` subsets based on request attributes
- Per-route timeouts and retries
- Distributed tracing header propagation (x-b3-*, traceparent)
- HTTP-level metrics (request rate, error rate, latency histograms) in the Consul UI

**What breaks without this file?**  
`ServiceRouter` and `ServiceSplitter` are silently ignored. `ServiceResolver` subsets still work
at L4 but you lose all routing rules. The Consul UI will show the service as `tcp` and HTTP
metrics will not appear on the topology graph.

---

### 6.8 Config Entry Dependency Graph

The full dependency chain for L7 traffic management in this project:

```
helm-values.yaml
  └── controller.enabled: true          (syncs all CRDs below into Consul)
  └── connectInject.enabled: true        (injects Envoy into pods)

ProxyDefaults (global)
  └── transparentProxy                   (removes need for upstream annotations)
  └── meshGateway.mode: local            (DC-local gateway preference)

ServiceDefaults (api-server)
  └── protocol: http                     ← REQUIRED before any L7 feature works
        │
        ├── ServiceResolver (api-server)
        │     └── subsets.stable         ← defines the named endpoint groups
        │
        ├── ServiceRouter (api-server)
        │     └── routes[*].destination.serviceSubset: stable
        │                                ← references ServiceResolver subsets
        │
        └── ServiceIntentions (api-server)
              └── sources: ui-app=allow  ← zero-trust authz (independent of protocol)

IngressGateway (ingress-gateway)
  └── listeners[0].services: ui-app      ← external entry point into the mesh
```

Apply order in `deploy-all.sh`:
1. `ProxyDefaults` — global mesh policy first
2. `ServiceResolver` — subsets must exist before the router references them
3. `ServiceRouter` — routing rules that reference resolver subsets
4. `IngressGateway` — gateway config (depends on ui-app being registered)
5. `ServiceDefaults` — protocol declaration (applied alongside workloads)
6. `ServiceIntentions` — access control (applied before pods start)

---

## 7. References

- [Consul Service Mesh docs](https://developer.hashicorp.com/consul/docs/connect)
- [Consul K8s Helm chart reference](https://developer.hashicorp.com/consul/docs/k8s/helm)
- [Config entries reference](https://developer.hashicorp.com/consul/docs/connect/config-entries)
- [Intentions reference](https://developer.hashicorp.com/consul/docs/connect/intentions)
- [Transparent proxy](https://developer.hashicorp.com/consul/docs/connect/transparent-proxy)
- [ServiceResolver reference](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-resolver)
- [ServiceRouter reference](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-router)
- [IngressGateway reference](https://developer.hashicorp.com/consul/docs/connect/config-entries/ingress-gateway)
