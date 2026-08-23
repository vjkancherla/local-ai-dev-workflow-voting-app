# Manual Testing Guide — Voting App

> Step-by-step guide for a human to verify the voting app end-to-end without relying
> solely on the automated `scripts/verify.sh`. Each section maps to the 17 requirements
> (R1–R17) documented in `README.md` and `.workflow/requirements.md`.

---

## Table of Contents

1. [Architecture Recap](#1-architecture-recap)
2. [Prerequisites](#2-prerequisites)
3. [Environment Setup](#3-environment-setup)
4. [Deploy the App](#4-deploy-the-app)
5. [Sanity Check: Is It Running?](#5-sanity-check-is-it-running)
6. [Functional Testing (R1–R6)](#6-functional-testing-r1r6)
7. [Data & Persistence Testing (R7–R9)](#7-data--persistence-testing-r7r9)
8. [Platform / Infrastructure Testing (R10–R17)](#8-platform--infrastructure-testing-r10r17)
9. [Manual Smoke Test (Browser)](#9-manual-smoke-test-browser)
10. [Known Gaps & Expected Behavior](#10-known-gaps--expected-behavior)
11. [Cleanup](#11-cleanup)

---

## 1. Architecture Recap

```
vote (Flask) ──RPUSH──> redis (queue) ──BLPOP──> worker (Python) ──upsert──> postgres
                                                                                  │
result (Flask) ◄────── SELECT / COUNT(*) / GROUP BY ──────────────────────────────┘
```

- **vote**: renders the voting page, assigns a per-browser UUID cookie, enqueues votes to Redis.
- **redis**: pure FIFO queue (`votes` list). No PVC, no AOF — votes are lost if the Redis *pod* restarts.
- **worker**: drains Redis, upserts one row per `voter_id` into Postgres (idempotent).
- **postgres**: stores the `votes` table (1Gi PVC). StatefulSet → stable pod name `voting-app-postgres-0`.
- **result**: queries Postgres, renders counts + percentages, auto-refreshes every 2s.

All traffic reaches the app through an **Ingress** on `vote.localhost`/`result.localhost`, routed via the k3d loadbalancer.

---

## 2. Prerequisites

Verify these are installed and on your `PATH` before starting:

| Tool | Check | Purpose |
|------|-------|---------|
| Docker | `docker --version` | Build images |
| k3d | `k3d version` | Local Kubernetes cluster |
| kubectl | `kubectl version --client` | Cluster control |
| jq | `jq --version` | JSON parsing in tests |
| openssl | `openssl version` | Secret generation |

> **Note (macOS arm64):** Images are built for `linux/arm64`. k3d runs a containerd-backed node; images are imported directly (default mode) or pulled from a cluster-internal registry (`REGISTRY=1`).

---

## 3. Environment Setup

The ingress hosts use the `.localhost` TLD, which resolves to `127.0.0.1` natively (RFC 6761) on macOS and
Linux — **no `/etc/hosts` entry and no external DNS (nip.io) are required**. Just deploy and open the URLs.
If you're on an unusual setup where `.localhost` doesn't resolve, add:

```bash
sudo tee -a /etc/hosts <<'EOF'
127.0.0.1 vote.localhost
127.0.0.1 result.localhost
EOF
```

Verify resolution:

```bash
nslookup vote.localhost      # should return 127.0.0.1
nslookup result.localhost    # should return 127.0.0.1
```

> If a later step can't reach the app over HTTPS, this is the first thing to check.

---

## 4. Deploy the App

```bash
./scripts/deploy.sh
```

What it does (idempotent):
1. Creates the `voting-app` k3d cluster **only if it doesn't already exist** (ports `8081`→HTTP, `8082`→HTTPS).
2. Builds the three images for `linux/arm64` and imports them into the cluster.
3. Generates `kustomize/postgres-secret.env` **once** (persisted; ignored by git).
4. Applies Kustomize and waits for all workloads to become ready.

**Registry mode** (fallback if port 5000 is taken by AirPlay, etc.):

```bash
REGISTRY=1 ./scripts/deploy.sh
# If port 5000 is busy:  REGISTRY=1 REGISTRY_PORT=5001 ./scripts/deploy.sh
```

Expected end of output:

```
Deploy complete.
  vote:   https://vote.localhost:8082/   (*.localhost resolves to 127.0.0.1 natively — no /etc/hosts needed)
  result: https://result.localhost:8082/
```

---

## 5. Sanity Check: Is It Running?

Confirm all five workloads are `Ready` and healthy:

```bash
# Pods
kubectl get pods

# Expected: vote, worker, result, redis each 1/1 Ready; postgres-0 1/1 Ready
```

Check the `/healthz` endpoints (self-signed certs → `-k`):

```bash
curl -sk https://vote.localhost:8082/healthz      # -> OK
curl -sk https://result.localhost:8082/healthz    # -> OK

# Worker has no HTTP server; its probe runs the app's --healthcheck:
POD=kubectl get pods -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}'
kubectl exec $POD -- python /app/app.py --healthcheck && echo "worker healthy"
```

> Redis and Postgres have no `/healthz` route. Verify them directly:
> ```bash
> kubectl exec deploy/voting-app-redis -- redis-cli ping            # -> PONG
> kubectl exec voting-app-postgres-0 -- pg_isready -U postgres     # -> accepting connections
> ```

If everything above is healthy, proceed. Otherwise re-run `deploy.sh` and re-check.

---

## 6. Functional Testing (R1–R6)

These exercise the live voting flow through the ingress. Use a **fresh browser cookie jar** per test so voter identity is isolated.

### R1 — Vote page offers exactly two options

```bash
curl -sk https://vote.localhost:8082/ | grep -o 'name="choice" value="[^"]*"'
```

✅ **Pass:** exactly two `value="..."` buttons (defaults: `Cats` and `Dogs`).

### R2 — Casting a vote enqueues it into Redis

Pause the worker so the vote stays in the queue, then cast one:

```bash
kubectl scale deployment/voting-app-worker --replicas=0
# wait for worker pods to disappear
kubectl get pods -l app.kubernetes.io/component=worker   # expect no worker pods
before=$(kubectl exec deploy/voting-app-redis -- redis-cli LLEN votes)
curl -sk -X POST https://vote.localhost:8082/vote -d "choice=Cats" -c /tmp/cj-r2.txt -o /dev/null -w '%{http_code}'
after=$(kubectl exec deploy/voting-app-redis -- redis-cli LLEN votes)
kubectl scale deployment/voting-app-worker --replicas=1
```

✅ **Pass:** `after` > `before` (the vote queued), and the POST returns `200`/`302`.

### R3 — One vote per browser (re-vote replaces, not adds)

```bash
curl -sk -c /tmp/cj-r3.txt https://vote.localhost:8082/ >/dev/null
curl -sk -X POST https://vote.localhost:8082/vote -d "choice=Cats" -b /tmp/cj-r3.txt -o /dev/null
sleep 3
curl -sk -X POST https://vote.localhost:8082/vote -d "choice=Dogs" -b /tmp/cj-r3.txt -o /dev/null
sleep 3
kubectl exec voting-app-postgres-0 -- psql -U postgres -d voting -t -A -c 'SELECT COUNT(*) FROM votes'
```

✅ **Pass:** count is `1` — the second vote replaced the first for the same `voter_id` cookie.

### R4 — Worker idempotency (replayed vote = one row)

```bash
kubectl exec deploy/voting-app-redis -- redis-cli RPUSH votes '{"voter_id":"manual-r4","choice":"Cats","timestamp":1700000000}'
kubectl exec deploy/voting-app-redis -- redis-cli RPUSH votes '{"voter_id":"manual-r4","choice":"Cats","timestamp":1700000000}'
sleep 3
kubectl exec voting-app-postgres-0 -- psql -U postgres -d voting -t -A -c "SELECT COUNT(*) FROM votes WHERE voter_id='manual-r4'"
```

✅ **Pass:** count is `1` — duplicate `voter_id` collapses to a single row.

### R5 — Result page shows counts and percentages

```bash
curl -sk https://result.localhost:8082/
```

✅ **Pass:** page lists both option labels (`Cats`, `Dogs`) with a numeric count and a `%` value for each.

### R6 — New vote appears in results within 5s

```bash
curl -sk -X POST https://vote.localhost:8082/vote -d "choice=Cats" -c /tmp/cj-r6.txt -o /dev/null
# Immediately poll the result page; the number next to Cats should increase within ~5 seconds.
```

✅ **Pass:** the vote is reflected on the result page within 5 seconds (the worker drains Redis → Postgres, result refreshes every 2s).

> **Note:** R3–R6 rely on the worker being at `replicas=1`. R2 temporarily scaled it to `0` and restored it.

---

## 7. Data & Persistence Testing (R7–R9)

### R7 — Schema is correct

```bash
kubectl exec voting-app-postgres-0 -- psql -U postgres -d voting -c '\d votes'
```

✅ **Pass:** table `votes` has columns `voter_id` (primary key), `choice`, `updated_at`.

### R8 — Queued votes survive a worker restart

```bash
kubectl scale deployment/voting-app-worker --replicas=0
kubectl get pods -l app.kubernetes.io/component=worker   # wait for all worker pods gone
curl -sk -X POST https://vote.localhost:8082/vote -d "choice=Dogs" -c /tmp/cj-r8.txt -o /dev/null
kubectl exec deploy/voting-app-redis -- redis-cli LLEN votes          # > 0 (queued)
kubectl scale deployment/voting-app-worker --replicas=1
kubectl rollout status deployment/voting-app-worker --timeout=120s
sleep 5
kubectl exec voting-app-postgres-0 -- psql -U postgres -d voting -t -A -c 'SELECT COUNT(*) FROM votes'
kubectl exec deploy/voting-app-redis -- redis-cli LLEN votes          # expect 0 (drained)
```

✅ **Pass:** the vote queued during the outage appears in Postgres after the worker restarts, and the Redis queue is drained to `0`.

### R9 — Tally survives a Postgres restart

```bash
before=$(kubectl exec voting-app-postgres-0 -- psql -U postgres -d voting -t -A -c 'SELECT COUNT(*) FROM votes')
kubectl delete pod voting-app-postgres-0
kubectl wait --for=condition=Ready pod/voting-app-postgres-0 --timeout=120s
sleep 5
after=$(kubectl exec voting-app-postgres-0 -- psql -U postgres -d voting -t -A -c 'SELECT COUNT(*) FROM votes')
echo "before=$before after=$after"
```

✅ **Pass:** `before == after` — the PVC preserves the tally across the StatefulSet pod restart.

> **Timing note:** Postgres has a 30s readiness delay on startup; the result service also needs a moment to reconnect. Give both a few seconds before concluding.

---

## 8. Platform / Infrastructure Testing (R10–R17)

### R10 — Liveness + readiness probes on all 5 workloads

```bash
kubectl get deploy,statefulset -o json | jq '
  [.items[] | .spec.template.spec.containers[] |
   {l: (.livenessProbe != null), r: (.readinessProbe != null)}]
  | "liveness=\(map(select(.l))|length) readiness=\(map(select(.r))|length)"'
```

✅ **Pass:** `liveness=5 readiness=5`.

### R11 — Resource requests AND limits on all 5

```bash
kubectl get deploy,statefulset -o json | jq '
  [.items[] | .spec.template.spec.containers[] |
   select(.resources.requests.cpu != null and .resources.requests.memory != null
          and .resources.limits.cpu != null and .resources.limits.memory != null)]
  | length'
```

✅ **Pass:** `5`.

### R12 — Single Kustomize config + registry image override

```bash
kubectl kustomize ./kustomize | grep -E 'vote|worker|result' | grep image
```

✅ **Pass:** builds cleanly and shows image refs (`vote:latest`, etc.). The `overlays/registry/` overlay redirects these to `k3d-voting-app-registry.localhost:5000/...` for registry-pull mode.

### R13 — Ingress HTTPS reachability

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://vote.localhost:8082/
curl -sk -o /dev/null -w '%{http_code}\n' https://result.localhost:8082/
```

✅ **Pass:** both return `200` over HTTPS on port `8082`.

### R14 — No NodePort services

```bash
kubectl get svc -o json | jq '[.items[] | select(.spec.type=="NodePort")] | length'
```

✅ **Pass:** `0`. All Services are `ClusterIP`.

### R15 — arm64 images, no pull failures

```bash
docker inspect vote:latest --format '{{.Architecture}}'
kubectl get pods
```

✅ **Pass:** architecture is `arm64` and no pod reports `ImagePullBackOff`.

### R16 — Every service reports dependency health

```bash
curl -sk https://vote.localhost:8082/healthz     # OK
curl -sk https://result.localhost:8082/healthz   # OK
POD=kubectl get pods -l app.kubernetes.io/component=worker -o jsonpath='{.items[0].metadata.name}'
kubectl exec $POD -- python /app/app.py --healthcheck && echo worker-ok
kubectl exec deploy/voting-app-redis -- redis-cli ping                 # PONG
kubectl exec voting-app-postgres-0 -- pg_isready -U postgres          # accepting connections
```

✅ **Pass:** all five dependency checks succeed.

### R17 — Credentials from a Secret, not committed YAML

```bash
grep -rn 'POSTGRES_PASSWORD' ./kustomize --include='*.yaml'   # expect NO matches
kubectl get secret voting-app-postgres -o jsonpath='{.data.POSTGRES_PASSWORD}' | wc -c
```

✅ **Pass:** no literal password in the manifests, and the Secret `voting-app-postgres` holds `POSTGRES_PASSWORD`.

> The Secret is generated from `kustomize/postgres-secret.env` (gitignored). In default mode the file contains placeholder credentials; `deploy.sh` randomizes them on first run.

---

## 9. Manual Smoke Test (Browser)

For a holistic, non-scripted check:

1. Open **https://result.localhost:8082/** — you should see the counts page (self-signed cert warning is expected; accept/proceed).
2. Open **https://vote.localhost:8082/** — vote for `Cats`.
3. Watch the result page refresh (every ~2s); the `Cats` count and percentage should tick up.
4. Reload the vote page in the **same browser tab** and vote for `Dogs` — the total vote count should **not** increase (one vote per browser).
5. Open the vote page in a **private/invisible window** and vote — this is a different `voter_id`, so it counts as a separate vote.

---

## 10. Known Gaps & Expected Behavior

These are documented, accepted characteristics — a "failure" here is often **expected**, not a bug:

| Area | Behavior | Reference |
|------|----------|-----------|
| **POSTGRES_DB mismatch** | Deployments set `PGDATABASE=voting` while `postgres-secret.env` says `POSTGRES_DB=votingdb`. The apps use `voting`; the `votingdb` DB may be empty. Not tested by R1–R17 but worth knowing. | README §3.2 |
| **Redis no AOF / no PVC** | Votes survive a *worker* restart but are **lost if the Redis pod restarts**. | README Known Gaps |
| **In-flight vote loss** | If the worker is killed between `BLPOP` and `COMMIT`, that single vote is lost (documented MVP limitation). | worker/app.py docstring |
| **Worker healthcheck breadth** | Returns healthy if Redis **and** Postgres are up — the pod can be "ready" while the queue is momentarily stuck. | README §2.2 |
| **Options must agree** | `vote` and `result` both default to `["Cats","Dogs"]` via the `OPTIONS` env var; there is no sync mechanism if you change one. | README §2.2 |
| **Ingress controller** | Ingress YAML references `traefik`; `deploy.sh` also installs nginx via Helm. On k3d, bundled Traefik handles traffic and nginx is redundant. | README §3.3 |

---

## 11. Cleanup

Delete the k3d cluster when done (no `/etc/hosts` entries to remove — `.localhost` resolves natively):

```bash
k3d cluster delete voting-app
# No /etc/hosts entries were added (.localhost resolves natively), so there is
# nothing to remove — only needed if you added them manually (see §3).
```

---

## Quick Reference

| Script | Command |
|--------|---------|
| Deploy | `./scripts/deploy.sh` |
| Full automated verification | `./scripts/verify.sh` → `.workflow/verify.md` |
| Cluster status | `kubectl get pods,svc,ingress` |
| Re-run a single check | Copy the snippet from the relevant section above |

**Tip:** Run `./scripts/verify.sh` for the machine-recorded R1–R17 report, and use this guide for the interactive, human-readable walkthrough that explains *why* each check matters.
