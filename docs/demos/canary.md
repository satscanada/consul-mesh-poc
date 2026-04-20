# Canary Deployment Demo — Testing Guide

This guide walks through the Step 12 canary flow using the dedicated `/canary` page, `api-server` v1/v2 subsets, and Consul's weighted service splitting.

> Weighted canary in Consul is implemented with a `ServiceSplitter`.
> In this repo, `ServiceRouter` still handles the `/api/*` match, while `ServiceSplitter` controls the `v1` / `v2` percentage.

---

## What Gets Created

- `api-server` stable deployment serves `APP_VERSION=v1`
- `api-server-v2` serves `APP_VERSION=v2`
- `consul/serviceresolver-canary.yaml` defines `v1` and `v2` subsets
- `consul/servicerouter-canary.yaml` matches `/api/*` traffic to `api-server`
- `consul/servicesplitter-canary.yaml` sets the weighted `v1` / `v2` split
- `ui-app/src/canary.html` visualizes real `/api/version` responses from the mesh-routed proxy

---

## Prerequisites

If the UI or `api-server:latest` changed recently:

```bash
./scripts/deploy-apps.sh
```

Then start the canary flow:

```bash
./scripts/canary-promote.sh
```

By default that script:

1. removes leftover `api-server-variant-b` A/B state if present
2. builds `api-server:v2`
3. applies the `api-server-v2` deployment
4. applies canary resolver/router/splitter config
5. walks through 10%, 25%, 50%, 75%, and 100% v2 traffic with confirmation prompts

If you already have the `api-server:v2` image locally:

```bash
./scripts/canary-promote.sh --skip-build
```

If you want to jump directly to a stage:

```bash
./scripts/canary-promote.sh 50
```

---

## Open the Canary Page

Port-forward the UI if needed:

```bash
kubectl port-forward svc/ui-app 4000:4000
```

Open:

```text
http://localhost:4000/canary
```

This page keeps its own local counters and measures real responses from:

```text
/api/version
```

---

## Verify the Split

After confirming a stage in `canary-promote.sh`:

1. open `/canary`
2. click `Run 20 Requests` or `Run 100 Requests`
3. watch the doughnut chart and recent-response list
4. compare the observed ratio against the configured canary stage

Expected examples:

- at 10% canary, most responses should be `v1` with some `v2`
- at 50% canary, the chart should trend toward an even split
- at 100% canary, all responses should be `v2`

Because traffic sampling is probabilistic, small request counts will not always be exact.

---

## Roll Back

To move traffic back to stable immediately:

```bash
./scripts/canary-rollback.sh
```

That reapplies the canary config and patches the splitter to:

- `v1`: 100%
- `v2`: 0%

---

## Handy Commands

```bash
./scripts/canary-promote.sh
./scripts/canary-promote.sh 50
./scripts/canary-promote.sh --skip-build
./scripts/canary-rollback.sh
kubectl get servicesplitter api-server -o yaml
kubectl get serviceresolver api-server -o yaml
kubectl get servicerouter api-server -o yaml
kubectl get pods -l app=api-server
```
