# Consul CNI Annotation

## What is `k8s.v1.cni.cncf.io/networks`?

```yaml
annotations:
  k8s.v1.cni.cncf.io/networks: '[{"name":"consul-cni"}]'
```

This annotation enables Consul's **CNI (Container Network Interface) plugin** to handle traffic redirection for the service mesh sidecar proxy (Envoy).

---

## Why it exists

When Consul injects an Envoy sidecar, it must redirect all pod traffic through the proxy using `iptables` rules. There are two ways to set this up:

| Method | How it works | Requires privileged container? |
|---|---|---|
| **Init container** (default) | A privileged `init` container runs `iptables` commands before the app starts | Yes |
| **CNI plugin** | Network rules are set up at the node level, outside the pod | No |

---

## When do you need it?

Use the CNI plugin (and this annotation) when your environment **blocks privileged init containers**, such as:

- **OpenShift** — enforces strict Security Context Constraints (SCC) by default
- Clusters with **Pod Security Admission (PSA)** in `restricted` mode
- Environments with strict **PodSecurityPolicy** rules

### OpenShift setup

1. Install Consul Helm with CNI enabled:

```yaml
connectInject:
  cni:
    enabled: true
    logLevel: info
    multus: true          # OpenShift uses Multus CNI
    cniBinDir: /var/lib/cni/bin
    cniNetDir: /etc/kubernetes/cni/net.d
```

2. Add the annotation to pod templates:

```yaml
annotations:
  consul.hashicorp.com/connect-inject: "true"
  k8s.v1.cni.cncf.io/networks: '[{"name":"consul-cni"}]'
```

---

## This project (EKS)

This POC targets **Amazon EKS**, which allows privileged init containers. The default init container method is used — the CNI annotation is **not needed**.

The `consul.hashicorp.com/connect-inject: "true"` annotation alone is sufficient for EKS deployments.
