# A/B Testing Demo — Testing Guide

This guide walks through the header-based A/B demo using the `api-server` stable deployment, the `variant-b` deployment, and Consul `ServiceRouter` / `ServiceResolver` config entries.

> `./scripts/ab-switch.sh` does not build images.
> Run `./scripts/deploy-apps.sh` if your cluster needs the latest app code from this branch.
> Run `./scripts/deploy-all.sh` only if the environment itself needs full bootstrap or reconfiguration.

---

## How It Works

The A/B demo uses one application image and two Consul subsets:

- `variant-a` is the default `api-server` deployment in `api-server/k8s/deployment.yaml`
- `variant-b` is the extra deployment in `api-server/k8s/deployment-variant-b.yaml`
- Both run `api-server:latest`
- The difference is driven by `APP_VARIANT` and Consul service metadata, not by separate images

Routing behavior:

- Requests without `X-User-Group: beta` match the fallback route and go to subset `variant-a`
- Requests with `X-User-Group: beta` match the first route in `consul/servicerouter-ab.yaml` and go to subset `variant-b`
- `consul/serviceresolver-ab.yaml` maps each subset to pods via `Service.Meta.variant`
- The API returns `X-Api-Variant`, and the UI displays which variant answered

Visible behavior:

- `variant-a` returns the normal item list
- `variant-b` decorates items with a beta label so the routed response is obvious

---

## Prerequisites

- Consul is installed and healthy
- The base app is deployed
- The cluster is running current images from this branch

If you have not rebuilt/redeployed since these A/B changes were added:

```bash
./scripts/deploy-apps.sh
```

That rebuilds `api-server:latest` and `ui-app:latest`, reapplies the app manifests, and forces a rollout so pods pick up the rebuilt `:latest` images.

---

## Step 1 — Open the UI

Use either the ingress route from `QUICKSTART.md` or port-forward `ui-app` directly:

```bash
kubectl port-forward svc/ui-app 4000:4000
```

Open:

```text
http://localhost:4000
```

You should see:

- The existing API version badge
- A new A/B panel with a checkbox labeled `Send X-User-Group: beta`
- A variant badge initially showing `variant-a` after the first request

---

## Step 2 — Enable the A/B Demo

```bash
./scripts/ab-switch.sh enable
```

What this does:

1. Applies `api-server/k8s/deployment-variant-b.yaml`
2. Applies `consul/serviceresolver-ab.yaml`
3. Applies `consul/servicerouter-ab.yaml`
4. Leaves the existing `api-server` deployment in place as `variant-a`
5. Automatically removes leftover `api-server-v2` blue-green deployment state if it exists

What it does not do:

- It does not build Docker images
- It does not rebuild `ui-app`
- It does not change traffic unless the request header is present

Check status anytime:

```bash
./scripts/ab-switch.sh status
```

---

## Step 3 — Verify Stable Traffic

With the beta checkbox turned off in the UI:

1. Refresh the page or click an action that calls `/api/items`
2. Confirm the variant badge shows `VARIANT-A`
3. Confirm item names/descriptions look unchanged

You can also verify with `curl` against the UI proxy:

```bash
curl -i http://localhost:4000/api/items
```

Look for:

```text
X-Api-Variant: variant-a
```

---

## Step 4 — Verify Beta Traffic

Turn on the `Send X-User-Group: beta` checkbox in the UI.

Then:

1. Refresh or add/delete an item
2. Confirm the variant badge changes to `VARIANT-B`
3. Confirm returned items are visibly decorated for beta, such as `Beta · <name>`

Equivalent `curl` test:

```bash
curl -i -H 'X-User-Group: beta' http://localhost:4000/api/items
```

Look for:

```text
X-Api-Variant: variant-b
```

and a beta-decorated JSON response body.

---

## Step 5 — Disable the Demo

```bash
./scripts/ab-switch.sh disable
```

This:

- Restores the baseline `ServiceRouter`
- Restores the baseline `ServiceResolver`
- Deletes the `variant-b` deployment

After that, all traffic returns to the normal stable path.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Variant badge never changes from `unknown` | Old `ui-app` image is running | Rebuild/redeploy with `./scripts/deploy-apps.sh` |
| Beta checkbox is on but traffic stays on `variant-a` | A/B router/resolver not applied | Run `./scripts/ab-switch.sh status` and confirm subsets |
| `variant-b` pod never appears | Deployment was not applied or image is stale | Run `./scripts/ab-switch.sh enable`; if needed rerun `./scripts/deploy-apps.sh` |
| No visual difference in response body | Old `api-server:latest` image is still running | Rebuild/redeploy with `./scripts/deploy-apps.sh` |
| `Error: no matches for kind "ServiceRouter"` | Consul CRDs are missing | Reinstall Consul with `./scripts/install-consul.sh` |

---

## Handy Commands

```bash
./scripts/ab-switch.sh enable
./scripts/ab-switch.sh status
./scripts/ab-switch.sh disable
kubectl get pods -l app=api-server
kubectl get servicerouter api-server -o yaml
kubectl get serviceresolver api-server -o yaml
```
