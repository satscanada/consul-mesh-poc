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

## 6. References

- [Consul Service Mesh docs](https://developer.hashicorp.com/consul/docs/connect)
- [Consul K8s Helm chart reference](https://developer.hashicorp.com/consul/docs/k8s/helm)
- [Config entries reference](https://developer.hashicorp.com/consul/docs/connect/config-entries)
- [Intentions reference](https://developer.hashicorp.com/consul/docs/connect/intentions)
- [Transparent proxy](https://developer.hashicorp.com/consul/docs/connect/transparent-proxy)
