#!/usr/bin/env bash
# install-consul-manual.sh — installs Consul OSS on Kubernetes WITHOUT Helm
# Designed for air-gapped / offline environments.
#
# Prerequisites (must be available locally — no internet required):
#   - kubectl  (configured and pointing at target cluster)
#   - openssl  (for TLS cert generation)
#   - base64, tr  (standard coreutils)
#
# Container images must be pre-pulled or available from a local/internal registry.
# Override image references via environment variables before running:
#
#   IMAGE_CONSUL=my-registry/consul:1.18.2 ./scripts/install-consul-manual.sh
#
# For CRD installation, place the consul-k8s CRD YAML files under:
#   scripts/consul-crds/
# Download them once from: https://github.com/hashicorp/consul-k8s/tree/main/control-plane/config/crd/bases
# and bundle them alongside this script for offline use.
#
# Run from the repo root: ./scripts/install-consul-manual.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration (override via env vars) ────────────────────────────────────
CONSUL_NAMESPACE="${CONSUL_NAMESPACE:-consul}"
DATACENTER="${DATACENTER:-dc1}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
RELEASE_NAME="consul"

# Image references — point these at a local registry in air-gapped environments
IMAGE_CONSUL="${IMAGE_CONSUL:-hashicorp/consul:1.18.2}"
IMAGE_CONSUL_K8S="${IMAGE_CONSUL_K8S:-hashicorp/consul-k8s-control-plane:1.3.10}"
IMAGE_CONSUL_DATAPLANE="${IMAGE_CONSUL_DATAPLANE:-hashicorp/consul-dataplane:1.3.10}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
b64()  { base64 < "$1" | tr -d '\n'; }        # portable: works on macOS & Linux

TLS_DIR=$(mktemp -d)
trap 'rm -rf "${TLS_DIR}"' EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────
log "Checking prerequisites"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v openssl >/dev/null 2>&1 || die "openssl not found in PATH"

CURRENT_CONTEXT=$(kubectl config current-context)
log "Active kubectl context: ${CURRENT_CONTEXT}"
if [[ "${CURRENT_CONTEXT}" != "docker-desktop" ]]; then
  echo "WARNING: current context is '${CURRENT_CONTEXT}', not 'docker-desktop'."
  read -r -p "Continue anyway? [y/N] " confirm
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ── Namespace ─────────────────────────────────────────────────────────────────
log "Creating namespace '${CONSUL_NAMESPACE}'"
kubectl create namespace "${CONSUL_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── Consul CRDs ───────────────────────────────────────────────────────────────
# In air-gapped mode, bundle the CRD YAMLs in scripts/consul-crds/.
# They cover: ServiceDefaults, ServiceIntentions, ServiceRouter, ServiceSplitter,
# ServiceResolver, ProxyDefaults, IngressGateway, TerminatingGateway, etc.
CRD_DIR="${SCRIPT_DIR}/consul-crds"
if [[ -d "${CRD_DIR}" ]]; then
  log "Applying Consul CRDs from ${CRD_DIR}"
  kubectl apply -f "${CRD_DIR}/"
else
  echo ""
  echo "  WARNING: ${CRD_DIR} not found — skipping CRD install."
  echo "  Consul config-entry resources (ServiceDefaults, ServiceIntentions, etc.)"
  echo "  will not work until CRDs are applied."
  echo "  Download CRDs from the consul-k8s release and place them in:"
  echo "    scripts/consul-crds/"
  echo ""
fi

# ── TLS — Consul CA ───────────────────────────────────────────────────────────
log "Generating Consul CA (self-signed)"
openssl genrsa -out "${TLS_DIR}/ca.key" 4096 2>/dev/null
openssl req -new -x509 -days 3650 \
  -key "${TLS_DIR}/ca.key" \
  -out "${TLS_DIR}/ca.crt" \
  -subj "/CN=Consul CA/O=HashiCorp" 2>/dev/null

# ── TLS — Server certificate ──────────────────────────────────────────────────
log "Generating Consul server TLS certificate"
openssl genrsa -out "${TLS_DIR}/server.key" 2048 2>/dev/null

cat > "${TLS_DIR}/server.cnf" <<CNF
[req]
req_extensions     = v3_req
distinguished_name = req_dn
prompt             = no

[req_dn]
CN = server.${DATACENTER}.consul

[v3_req]
keyUsage         = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = server.${DATACENTER}.consul
DNS.2 = ${RELEASE_NAME}-server
DNS.3 = ${RELEASE_NAME}-server.${CONSUL_NAMESPACE}
DNS.4 = ${RELEASE_NAME}-server.${CONSUL_NAMESPACE}.svc
DNS.5 = ${RELEASE_NAME}-server.${CONSUL_NAMESPACE}.svc.${CLUSTER_DOMAIN}
DNS.6 = *.${RELEASE_NAME}-server.${CONSUL_NAMESPACE}.svc
DNS.7 = *.${RELEASE_NAME}-server.${CONSUL_NAMESPACE}.svc.${CLUSTER_DOMAIN}
DNS.8 = localhost
IP.1  = 127.0.0.1
CNF

openssl req -new \
  -key "${TLS_DIR}/server.key" \
  -out "${TLS_DIR}/server.csr" \
  -config "${TLS_DIR}/server.cnf" 2>/dev/null

openssl x509 -req -days 3650 \
  -in "${TLS_DIR}/server.csr" \
  -CA "${TLS_DIR}/ca.crt" \
  -CAkey "${TLS_DIR}/ca.key" \
  -CAcreateserial \
  -out "${TLS_DIR}/server.crt" \
  -extensions v3_req \
  -extfile "${TLS_DIR}/server.cnf" 2>/dev/null

# ── TLS — Connect-inject webhook certificate ──────────────────────────────────
log "Generating connect-inject webhook TLS certificate"
WEBHOOK_SVC="${RELEASE_NAME}-connect-injector"
openssl genrsa -out "${TLS_DIR}/webhook.key" 2048 2>/dev/null

cat > "${TLS_DIR}/webhook.cnf" <<CNF
[req]
req_extensions     = v3_req
distinguished_name = req_dn
prompt             = no

[req_dn]
CN = ${WEBHOOK_SVC}.${CONSUL_NAMESPACE}.svc

[v3_req]
keyUsage         = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = ${WEBHOOK_SVC}
DNS.2 = ${WEBHOOK_SVC}.${CONSUL_NAMESPACE}
DNS.3 = ${WEBHOOK_SVC}.${CONSUL_NAMESPACE}.svc
DNS.4 = ${WEBHOOK_SVC}.${CONSUL_NAMESPACE}.svc.${CLUSTER_DOMAIN}
CNF

openssl req -new \
  -key "${TLS_DIR}/webhook.key" \
  -out "${TLS_DIR}/webhook.csr" \
  -config "${TLS_DIR}/webhook.cnf" 2>/dev/null

openssl x509 -req -days 3650 \
  -in "${TLS_DIR}/webhook.csr" \
  -CA "${TLS_DIR}/ca.crt" \
  -CAkey "${TLS_DIR}/ca.key" \
  -CAcreateserial \
  -out "${TLS_DIR}/webhook.crt" \
  -extensions v3_req \
  -extfile "${TLS_DIR}/webhook.cnf" 2>/dev/null

# ── Gossip encryption key ─────────────────────────────────────────────────────
log "Generating gossip encryption key"
GOSSIP_KEY=$(openssl rand -base64 32)

# ── Base64-encode all secrets ─────────────────────────────────────────────────
CA_CRT_B64=$(b64 "${TLS_DIR}/ca.crt")
CA_KEY_B64=$(b64 "${TLS_DIR}/ca.key")
SERVER_CRT_B64=$(b64 "${TLS_DIR}/server.crt")
SERVER_KEY_B64=$(b64 "${TLS_DIR}/server.key")
WEBHOOK_CRT_B64=$(b64 "${TLS_DIR}/webhook.crt")
WEBHOOK_KEY_B64=$(b64 "${TLS_DIR}/webhook.key")
GOSSIP_KEY_B64=$(printf '%s' "${GOSSIP_KEY}" | base64 | tr -d '\n')

# ── Secrets ───────────────────────────────────────────────────────────────────
log "Creating TLS and gossip Secrets"
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: consul-ca-cert
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
type: Opaque
data:
  tls.crt: ${CA_CRT_B64}
---
apiVersion: v1
kind: Secret
metadata:
  name: consul-ca-key
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
type: Opaque
data:
  tls.key: ${CA_KEY_B64}
---
apiVersion: v1
kind: Secret
metadata:
  name: consul-server-cert
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
type: kubernetes.io/tls
data:
  tls.crt: ${SERVER_CRT_B64}
  tls.key: ${SERVER_KEY_B64}
---
apiVersion: v1
kind: Secret
metadata:
  name: consul-connect-inject-webhook-cert
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
type: kubernetes.io/tls
data:
  tls.crt: ${WEBHOOK_CRT_B64}
  tls.key: ${WEBHOOK_KEY_B64}
---
apiVersion: v1
kind: Secret
metadata:
  name: consul-gossip-encryption-key
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
type: Opaque
data:
  key: ${GOSSIP_KEY_B64}
EOF

# ── ServiceAccounts ───────────────────────────────────────────────────────────
log "Creating ServiceAccounts"
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: consul-server
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: server
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: consul-connect-injector
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: connect-injector
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: consul-controller
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: controller
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: consul-ingress-gateway
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: ingress-gateway
EOF

# ── RBAC ──────────────────────────────────────────────────────────────────────
log "Creating RBAC (ClusterRoles and ClusterRoleBindings)"
kubectl apply -f - <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: consul-server
  labels:
    app: consul
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: consul-server
  labels:
    app: consul
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: consul-server
subjects:
  - kind: ServiceAccount
    name: consul-server
    namespace: ${CONSUL_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: consul-connect-injector
  labels:
    app: consul
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "services", "endpoints", "nodes", "secrets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["update", "patch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["consul.hashicorp.com"]
    resources: ["*"]
    verbs: ["*"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create", "get", "list", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: consul-connect-injector
  labels:
    app: consul
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: consul-connect-injector
subjects:
  - kind: ServiceAccount
    name: consul-connect-injector
    namespace: ${CONSUL_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: consul-controller
  labels:
    app: consul
rules:
  - apiGroups: [""]
    resources: ["configmaps", "events", "secrets", "serviceaccounts", "services"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: ["consul.hashicorp.com"]
    resources: ["*"]
    verbs: ["*"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create", "get", "list", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: consul-controller
  labels:
    app: consul
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: consul-controller
subjects:
  - kind: ServiceAccount
    name: consul-controller
    namespace: ${CONSUL_NAMESPACE}
EOF

# ── ConfigMap — server config ─────────────────────────────────────────────────
log "Creating server ConfigMap"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: consul-server-config
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: server
data:
  server.json: |
    {
      "datacenter": "${DATACENTER}",
      "domain": "consul",
      "data_dir": "/consul/data",
      "log_level": "INFO",
      "server": true,
      "bootstrap_expect": 1,
      "ui_config": { "enabled": true },
      "connect": { "enabled": true },
      "ports": {
        "https": 8501,
        "http":  8500,
        "grpc":  8502
      },
      "tls": {
        "defaults": {
          "ca_file":        "/consul/tls/ca/tls.crt",
          "cert_file":      "/consul/tls/server/tls.crt",
          "key_file":       "/consul/tls/server/tls.key",
          "verify_incoming": false,
          "verify_outgoing": true
        },
        "internal_rpc": {
          "verify_server_hostname": true
        }
      },
      "auto_encrypt": { "allow_tls": true },
      "telemetry": {
        "prometheus_retention_time": "60s",
        "disable_hostname": true
      }
    }
EOF

# ── Services ──────────────────────────────────────────────────────────────────
log "Creating Services"
kubectl apply -f - <<EOF
---
# Headless service — required for StatefulSet pod DNS and server discovery
apiVersion: v1
kind: Service
metadata:
  name: consul-server
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: server
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: consul
    component: server
  ports:
    - { name: https,       port: 8501, targetPort: 8501 }
    - { name: http,        port: 8500, targetPort: 8500 }
    - { name: grpc,        port: 8502, targetPort: 8502 }
    - { name: serflan-tcp, port: 8301, targetPort: 8301, protocol: TCP  }
    - { name: serflan-udp, port: 8301, targetPort: 8301, protocol: UDP  }
    - { name: serfwan-tcp, port: 8302, targetPort: 8302, protocol: TCP  }
    - { name: serfwan-udp, port: 8302, targetPort: 8302, protocol: UDP  }
    - { name: server-rpc,  port: 8300, targetPort: 8300 }
    - { name: dns-tcp,     port: 8600, targetPort: 8600, protocol: TCP  }
    - { name: dns-udp,     port: 8600, targetPort: 8600, protocol: UDP  }
---
# UI service — port-forward or expose externally via kubectl
apiVersion: v1
kind: Service
metadata:
  name: consul-ui
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: ui
spec:
  type: ClusterIP
  selector:
    app: consul
    component: server
  ports:
    - { name: http,  port: 80,  targetPort: 8500 }
    - { name: https, port: 443, targetPort: 8501 }
---
# Connect-inject webhook service
apiVersion: v1
kind: Service
metadata:
  name: consul-connect-injector
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: connect-injector
spec:
  type: ClusterIP
  selector:
    app: consul
    component: connect-injector
  ports:
    - { name: https, port: 443, targetPort: 8080 }
---
# Ingress gateway service
apiVersion: v1
kind: Service
metadata:
  name: consul-ingress-gateway
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: ingress-gateway
spec:
  type: LoadBalancer
  selector:
    app: consul
    component: ingress-gateway
  ports:
    - { name: gateway, port: 8080, targetPort: 8080 }
EOF

# ── Consul server StatefulSet ─────────────────────────────────────────────────
log "Creating Consul server StatefulSet"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: consul-server
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: server
spec:
  serviceName: consul-server
  replicas: 1
  selector:
    matchLabels:
      app: consul
      component: server
  template:
    metadata:
      labels:
        app: consul
        component: server
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port:   "8500"
        prometheus.io/path:   "/v1/agent/metrics"
    spec:
      serviceAccountName: consul-server
      terminationGracePeriodSeconds: 30
      securityContext:
        fsGroup: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        runAsUser: 100
      volumes:
        - name: config
          configMap:
            name: consul-server-config
        - name: tls-ca
          secret:
            secretName: consul-ca-cert
        - name: tls-server
          secret:
            secretName: consul-server-cert
      containers:
        - name: consul
          image: ${IMAGE_CONSUL}
          imagePullPolicy: IfNotPresent
          ports:
            - { containerPort: 8500, name: http       }
            - { containerPort: 8501, name: https      }
            - { containerPort: 8502, name: grpc       }
            - { containerPort: 8301, name: serflan    }
            - { containerPort: 8300, name: server-rpc }
            - { containerPort: 8600, name: dns        }
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: GOSSIP_KEY
              valueFrom:
                secretKeyRef:
                  name: consul-gossip-encryption-key
                  key: key
          command:
            - "/bin/sh"
            - "-ec"
            - |
              exec /bin/consul agent \
                -config-dir=/consul/config \
                -advertise=\$(POD_IP) \
                -bind=0.0.0.0 \
                -encrypt=\$(GOSSIP_KEY) \
                -retry-join=consul-server.${CONSUL_NAMESPACE}.svc.${CLUSTER_DOMAIN}
          volumeMounts:
            - { name: data,       mountPath: /consul/data                  }
            - { name: config,     mountPath: /consul/config                }
            - { name: tls-ca,     mountPath: /consul/tls/ca,    readOnly: true }
            - { name: tls-server, mountPath: /consul/tls/server, readOnly: true }
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:
            httpGet:
              path: /v1/status/leader
              port: 8500
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /v1/status/leader
              port: 8500
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 3
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
EOF

# ── Connect-inject webhook Deployment ─────────────────────────────────────────
log "Creating connect-inject webhook Deployment"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consul-connect-injector
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: connect-injector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: consul
      component: connect-injector
  template:
    metadata:
      labels:
        app: consul
        component: connect-injector
    spec:
      serviceAccountName: consul-connect-injector
      volumes:
        - name: webhook-certs
          secret:
            secretName: consul-connect-inject-webhook-cert
        - name: consul-ca
          secret:
            secretName: consul-ca-cert
      containers:
        - name: sidecar-injector
          image: ${IMAGE_CONSUL_K8S}
          imagePullPolicy: IfNotPresent
          ports:
            - { containerPort: 8080, name: https }
            - { containerPort: 9445, name: metrics }
          command:
            - "/bin/consul-k8s-control-plane"
            - "inject-connect"
            - "-consul-k8s-image=${IMAGE_CONSUL_K8S}"
            - "-consul-dataplane-image=${IMAGE_CONSUL_DATAPLANE}"
            - "-listen=:8080"
            - "-default-inject=false"
            - "-consul-address=consul-server.${CONSUL_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
            - "-tls-cert-dir=/etc/connect-injector/certs"
            - "-log-level=info"
            - "-enable-transparent-proxy=true"
            - "-default-enable-transparent-proxy=true"
          volumeMounts:
            - { name: webhook-certs, mountPath: /etc/connect-injector/certs, readOnly: true }
            - { name: consul-ca,     mountPath: /etc/consul/tls/ca,          readOnly: true }
          readinessProbe:
            httpGet:
              path: /readyz/ready
              port: 9445
              scheme: HTTPS
            initialDelaySeconds: 15
            periodSeconds: 10
EOF

# ── MutatingWebhookConfiguration ─────────────────────────────────────────────
log "Creating MutatingWebhookConfiguration"
kubectl apply -f - <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: consul-connect-injector
  labels:
    app: consul
webhooks:
  - name: consul-connect-injector.consul.hashicorp.com
    admissionReviewVersions: ["v1", "v1beta1"]
    clientConfig:
      caBundle: ${CA_CRT_B64}
      service:
        name: consul-connect-injector
        namespace: ${CONSUL_NAMESPACE}
        path: /mutate
    rules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
    failurePolicy: Fail
    sideEffects: None
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-public", "${CONSUL_NAMESPACE}"]
EOF

# ── Controller Deployment ─────────────────────────────────────────────────────
log "Creating consul-controller Deployment"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consul-controller
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: controller
spec:
  replicas: 1
  selector:
    matchLabels:
      app: consul
      component: controller
  template:
    metadata:
      labels:
        app: consul
        component: controller
    spec:
      serviceAccountName: consul-controller
      containers:
        - name: controller
          image: ${IMAGE_CONSUL_K8S}
          imagePullPolicy: IfNotPresent
          command:
            - "/bin/consul-k8s-control-plane"
            - "controller"
            - "-consul-address=consul-server.${CONSUL_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
            - "-datacenter=${DATACENTER}"
            - "-log-level=info"
          env:
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
EOF

# ── Ingress Gateway Deployment ────────────────────────────────────────────────
log "Creating Ingress Gateway Deployment"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: consul-ingress-gateway
  namespace: ${CONSUL_NAMESPACE}
  labels:
    app: consul
    component: ingress-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: consul
      component: ingress-gateway
  template:
    metadata:
      labels:
        app: consul
        component: ingress-gateway
      annotations:
        # Prevent the connect-inject webhook from injecting a sidecar into
        # the gateway pod — it manages its own dataplane process.
        consul.hashicorp.com/connect-inject: "false"
    spec:
      serviceAccountName: consul-ingress-gateway
      # hostNetwork + ClusterFirstWithHostNet: fixes "cannot bind HOST_IP:20200"
      # on Docker Desktop (same workaround used in helm-values.yaml).
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: ingress-gateway
          image: ${IMAGE_CONSUL_DATAPLANE}
          imagePullPolicy: IfNotPresent
          ports:
            - { containerPort: 8080,  name: gateway      }
            - { containerPort: 20000, name: proxy-health  }
          env:
            - name: HOST_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
          command:
            - "/bin/consul-dataplane"
            - "-addresses=consul-server.${CONSUL_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
            - "-grpc-port=8502"
            - "-proxy-service-id=ingress-gateway"
            - "-service-node-name=ingress-gateway"
            - "-log-level=info"
            - "-envoy-ready-bind-addr=\$(HOST_IP)"
            - "-envoy-admin-bind-port=19000"
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: /ready
              port: 20000
            initialDelaySeconds: 10
            periodSeconds: 10
EOF

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "Manual Consul installation complete. Pod status:"
kubectl get pods -n "${CONSUL_NAMESPACE}"

echo ""
echo "================================================================"
echo " Consul UI — port-forward command:"
echo ""
echo "   kubectl port-forward svc/consul-ui -n consul 8500:80"
echo ""
echo "   Then open: http://localhost:8500"
echo "================================================================"
echo ""
echo " Air-gapped image checklist"
echo " Pre-pull these images and push to your local registry, then"
echo " re-run with IMAGE_* env vars pointing at the local copies:"
echo ""
echo "   ${IMAGE_CONSUL}"
echo "   ${IMAGE_CONSUL_K8S}"
echo "   ${IMAGE_CONSUL_DATAPLANE}"
echo "================================================================"
