# Visualization Dashboard — Build Tracker

> Feature: Real-time blue-green traffic monitor inside `ui-app`  
> Branch: `feature/step-10-blue-green`  
> Related: [blue-green.md](./blue-green.md)

---

## Status

| # | Task | File(s) | Status |
|---|------|---------|--------|
| 1 | In-memory hit counter store | `ui-app/server.js` | ✅ Done |
| 2 | Increment counter in proxy handler | `ui-app/server.js` | ✅ Done |
| 3 | `GET /internal/stats` endpoint | `ui-app/server.js` | ✅ Done |
| 4 | `GET /internal/stats/stream` SSE endpoint | `ui-app/server.js` | ✅ Done |
| 5 | `DELETE /internal/stats` reset endpoint | `ui-app/server.js` | ✅ Done |
| 6 | Load Chart.js 4 from CDN | `ui-app/src/index.html` | ✅ Done |
| 7 | Traffic Monitor section (chart + log + buttons) | `ui-app/src/index.html` | ✅ Done |
| 8 | SSE client → live chart update | `ui-app/src/index.html` | ✅ Done |
| 9 | Add Step 13 work item to TODO.md | `TODO.md` | ✅ Done |

---

## Verification Checklist

- [ ] `curl http://localhost:4000/internal/stats` returns `{"v1":0,"v2":0,"total":0,"timeline":[]}`
- [ ] `curl http://localhost:4000/internal/stats/stream` streams `data:` lines every second
- [ ] Click "Simulate 20 requests" → chart bars grow, total reaches 20
- [ ] Run `./scripts/blue-green-cutover.sh v2` → simulate again → green bar grows
- [ ] Click Reset → counters zero, chart clears, timeline empty
- [ ] Timeline log shows up to 5 most recent entries with correct timestamps
- [ ] Version badge and chart update independently (badge per-request, chart via SSE)
