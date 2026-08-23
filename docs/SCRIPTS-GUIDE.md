# Build, Test & Scripts Guide — Voting App

> Practical guide for building the images, deploying the app, and running verification on a local
> k3d cluster. This covers the three scripts in `scripts/` (`build.sh`, `deploy.sh`, `verify.sh`) —
> what each does, the environment variables that tune them, common workflows, and troubleshooting.
>
> 👉 For the human, requirement-by-requirement walkthrough (R1–R17), see
> [`MANUAL-TESTING-GUIDE.md`](MANUAL-TESTING-GUIDE.md). This doc is the *operator's* companion:
> how to build, deploy, and use the scripts themselves.

---

## Table of Contents

1. [Architecture Recap](#architecture-recap)
2. [Prerequisites](#prerequisites)
3. [Environment Setup](#environment-setup)
4. [The Scripts](#the-scripts)
5. [`scripts/build.sh`](#scriptssh-buildsh-build-the-images)
6. [`scripts/deploy.sh`](#scriptssh-deploysh-deploy-the-app)
7. [`scripts/verify.sh`](#scriptssh-verifysh-verify-r1r17)
8. [Common Workflows](#common-workflows)
9. [Environment Variables & Configuration](#environment-variables--configuration)
10. [Troubleshooting](#troubleshooting)
11. [Known Limitations](#known-limitations)
12. [Cleanup](#cleanup)
13. [Quick Reference](#quick-reference)

---

<a name="architecture-recap">

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

All traffic reaches the app through an **Ingress** on `127.0.0.1.nip.io`, routed via the k3d loadbalancer
on host ports `8081` (HTTP) and `8082` (HTTPS).

**Platform:** k3d (lightweight Kubernetes) on macOS arm64, deployed via Kustomize. Images are built for
`linux/arm64` and loaded into the cluster either by direct `k3d image import` (default) or by pushing to a
cluster-internal registry (`REGISTRY=1`).

---

<a name="prerequisites">

## 2. Prerequisites

Verify these are installed and on your `PATH` before starting:

| Tool | Check | Purpose |
|------|-------|---------|
| Docker | `docker --version` | Build images |
| k3d | `k3d version` | Local Kubernetes cluster |
| kubectl | `kubectl version --client` | Cluster control |
| jq | `jq --version` | JSON parsing in verify.sh |
| openssl | `openssl version` | Secret generation on first deploy |

> **macOS arm64:** Images are built for `linux/arm64`. k3d runs a containerd-backed node; images are
> imported directly (default mode) or pulled from a cluster-internal registry (`REGISTRY=1`).

---

<a name="environment-setup">

## 3. Environment Setup

The ingress hosts are resolved through **nip.io** (a wildcard DNS service) to `127.0.0.1`. Add them to
`/etc/hosts` **before** deploying:

```bash
sudo tee -a /etc/hosts <<'EOF'
127.0.0.1 vote.127.0.0.1.nip.io
127.0.0.1 result.127.0.0.1.nip.io
EOF
```

Verify resolution (required by `verify.sh` — it assumes these entries exist):

```bash
getent hosts vote.127.0.0.1.nip.io      # should return 127.0.0.1
getent hosts result.127.0.0.1.nip.io    # should return 127.0.0.1
```

> If any script can't reach the app over HTTPS, `/etc/hosts` is the first thing to check.
> `verify.sh` does **not** verify this before running — set it up manually.

---

<a name="the-scripts">

## 4. The Scripts

Three scripts in `scripts/` make up the build → deploy → verify pipeline:

| Script | Command | What it does |
|--------|---------|--------------|
| `build.sh` | `./scripts/build.sh` | Build the 3 images (`vote`, `worker`, `result`) for `linux/arm64` and load them into the cluster |
| `deploy.sh` | `./scripts/deploy.sh` | Create the cluster (if missing), build + load images, generate secrets, apply Kustomize, wait for ready |
| `verify.sh` | `./scripts/verify.sh` | Run all 17 requirements (R1–R17), print a PASS/FAIL summary, append results to `.workflow/verify.md` |

**Typical order:** `build.sh` is called *by* `deploy.sh`, so you rarely run it directly. The normal flow is:

```bash
./scripts/deploy.sh      # cluster + images + manifests
./scripts/verify.sh      # R1–R17 → .workflow/verify.md
```

Use `build.sh` directly when you only need to (re)build and load images after changing app code,
without re-applying manifests.

---

<a name="scriptssh-buildsh-build-the-images">

## 5. `scripts/build.sh` — Build the Images

Builds the three application images for `linux/arm64` and loads them into the k3d cluster.

**Two modes:**

| Mode | When | Flow |
|------|------|------|
| **Default (primary)** | Everyday local dev | `docker build` → `k3d image import` directly into the cluster's containerd. No registry, no push, no `.local` DNS. |
| **Registry (`REGISTRY=1`)** | When port 5000 is taken (e.g. macOS AirPlay) | `docker build` → `docker push localhost:5000/{svc}:latest` → `deploy.sh` uses `overlays/registry` to point image refs at the k3d registry. |

**What it does:**

1. Builds each service with `docker build --platform linux/arm64 -t "{svc}:latest" "./{svc}"`.
2. **Default mode:** `k3d image import "{svc}:latest" -c "$CLUSTER"` directly into the cluster.
3. **Registry mode:** `docker push "localhost:${REGISTRY_PORT}/{svc}:latest"`.

**Image names:**
- Import mode: `vote:latest`, `worker:latest`, `result:latest`
- Registry mode: `localhost:${REGISTRY_PORT}/vote:latest` (etc.)

**Run it:**

```bash
./scripts/build.sh                              # default import mode
CLUSTER=mycluster ./scripts/build.sh            # custom cluster name
REGISTRY=1 ./scripts/build.sh                   # registry mode
REGISTRY=1 REGISTRY_PORT=5001 ./scripts/build.sh # registry on a non-default port
```

> **macOS note:** AirPlay Receiver may claim port 5000. If so, use `REGISTRY_PORT=5001` and deploy with
> `REGISTRY=1` (and edit `kustomize/overlays/registry/kustomization.yaml` to port 5001 if needed).

---

<a name="scriptssh-deploysh-deploy-the-app">

## 6. `scripts/deploy.sh` — Deploy the App

End-to-end, **idempotent** deployment script.

**Steps (in order):**

1. **Create the cluster if missing:**
   `k3d cluster create voting-app -p "8081:80@loadbalancer" -p "8082:443@loadbalancer" --agents 1`
   (+ `--registry-create voting-app-registry.localhost:${REGISTRY_PORT}` when `REGISTRY=1`).
   Runs only if the cluster doesn't already exist — safe to re-run.
2. **Build + load images** by calling `build.sh` (passing `REGISTRY`, `REGISTRY_PORT`, `CLUSTER`).
3. **Generate `kustomize/postgres-secret.env` once** (persisted across applies):
   `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=$(openssl rand -hex 16)`, `SECRET_KEY=$(openssl rand -hex 16)`.
   Ignored by git — do not commit.
4. **Apply Kustomize:** `kubectl apply -k kustomize/` (or `kustomize/overlays/registry/` in registry mode).
5. **Wait for ready:** `kubectl rollout status` on all 5 workloads (300s timeout each).

**Run it:**

```bash
./scripts/deploy.sh
```

Expected end of output:

```
Deploy complete.
  Add to /etc/hosts: 127.0.0.1 vote.127.0.0.1.nip.io result.127.0.0.1.nip.io
  vote:   https://vote.127.0.0.1.nip.io:8082/
  result: https://result.127.0.0.1.nip.io:8082/
```

**Registry mode** (fallback if port 5000 is busy):

```bash
REGISTRY=1 ./scripts/deploy.sh
REGISTRY=1 REGISTRY_PORT=5001 ./scripts/deploy.sh   # if port 5000 is busy
```

**Idempotency:** the cluster is created only if absent; `postgres-secret.env` is generated only once, so
Postgres credentials and the Flask `SECRET_KEY` stay stable across re-deploys.

---

<a name="scriptssh-verifysh-verify-r1r17">

## 7. `scripts/verify.sh` — Verify R1–R17

Full automated verification of all 17 requirements. Prints a per-requirement PASS/FAIL table and a summary
line (`===== N PASS, M FAIL =====`), and appends the same output to `.workflow/verify.md`.

**Prerequisites:** a running cluster (from `deploy.sh`) **and** the `/etc/hosts` entries from §3.

**Run it:**

```bash
./scripts/verify.sh
```

**What each requirement checks:**

| Req | Test |
|-----|------|
| R1 | GET /vote returns 200 with exactly two option buttons |
| R2 | POST /vote with worker scaled to 0 → Redis `LLEN votes` increases |
| R3 | Two POSTs with the same cookie → tally unchanged (one vote per browser) |
| R4 | Replay the same `voter_id` twice → one row (worker idempotency) |
| R5 | GET /result shows counts and percentages for both options |
| R6 | A new vote appears in the tally within 5s |
| R7 | `psql \d votes` has `voter_id`, `choice`, `updated_at` |
| R8 | Stop worker, vote (queue), restart worker → vote drains to Postgres, Redis drained to 0 |
| R9 | Delete the Postgres pod, wait ready → tally unchanged |
| R10 | All 5 workloads have liveness AND readiness probes |
| R11 | All 5 have resource requests AND limits |
| R12 | `kubectl kustomize` builds; registry image override works |
| R13 | HTTPS GET to both ingress hosts returns 200 |
| R14 | 0 NodePort services (all ClusterIP) |
| R15 | `vote:latest` is arm64; no `ImagePullBackOff` (import mode) / ≥3 registry refs (registry mode) |
| R16 | `/healthz` (vote, result), worker `--healthcheck`, Redis `PONG`, Postgres `pg_isready` all succeed |
| R17 | No literal `POSTGRES_PASSWORD` in manifests; Secret `voting-app-postgres` holds the password |

**Implementation notes:**
- Uses `-k`/`--compressed` on all `curl` calls (self-signed certs, gzip).
- Accepts HTTP `2xx`/`3xx` for the vote POST (Flask `redirect()`).
- Uses `sed`-based image override for R12 (avoids a `kubectl kustomize` cycle).
- `set -uo pipefail` (note: **not** `-e`) — each check handles its own errors so one failure doesn't abort the run.
- Results are written fresh each run: the file is **truncated** at the start (`: > "$OUT"`) and then
  filled in per-check, so each run overwrites (not accumulates) the report.

> **Timing:** R9 waits up to 120s for the Postgres pod to return and polls until both Postgres and the result
> pod are `Ready` (Postgres has a 30s readiness delay). Don't conclude early if you run checks manually.

---

<a name="common-workflows">

## 8. Common Workflows

**Fresh start (everything):**

```bash
# §3: add /etc/hosts entries first
./scripts/deploy.sh
./scripts/verify.sh
```

**After changing app code (vote/worker/result):** rebuild + re-deploy manifests:

```bash
./scripts/deploy.sh        # build.sh runs automatically; manifests re-applied
./scripts/verify.sh
```

**Just rebuild + load images (no manifest change):**

```bash
./scripts/build.sh
```

**Re-verify only (cluster already running):**

```bash
./scripts/verify.sh
```

**Registry mode (port 5000 busy):**

```bash
REGISTRY=1 REGISTRY_PORT=5001 ./scripts/deploy.sh
./scripts/verify.sh        # pass REGISTRY=1 so R15 checks registry refs
```

**Custom cluster name:**

```bash
CLUSTER=mycluster ./scripts/deploy.sh
```

> `verify.sh` supports a custom `CLUSTER` via `RELEASE` for label selectors and the auto-detected
> Postgres pod name — **except** R9's readiness loop hardcodes `voting-app-postgres-0` (see §11). For a
> full `verify.sh` run, keep the default cluster name `voting-app`, or override `PGPOD` and expect R9's
> readiness wait to reference the default name.

---

<a name="environment-variables--configuration">

## 9. Environment Variables & Configuration

All variables are optional; defaults are shown.

| Variable | Script(s) | Default | Purpose |
|----------|-----------|---------|---------|
| `CLUSTER` | build.sh, deploy.sh | `voting-app` | k3d cluster name |
| `REGISTRY` | build.sh, deploy.sh, verify.sh | `0` | `1` = registry mode (push to cluster registry instead of import) |
| `REGISTRY_PORT` | build.sh, deploy.sh | `5000` | Host port for the k3d registry (change if AirPlay claims 5000) |
| `KUSTOMIZE_DIR` | deploy.sh, verify.sh | `./kustomize` | Base Kustomize directory to apply |
| `RELEASE` | verify.sh | `voting-app` | Release name used in label selectors and pod-name lookups |
| `VOTE_URL` | verify.sh | `https://vote.127.0.0.1.nip.io:8082` | Override the vote base URL |
| `RESULT_URL` | verify.sh | `https://result.127.0.0.1.nip.io:8082` | Override the result base URL |
| `PGPOD` | verify.sh | auto-detected | Force a specific Postgres pod name (usually left unset) |
| `OUT` | verify.sh | `.workflow/verify.md` | Where the PASS/FAIL report is written (truncated at start, filled per-check) |

**Registry overlay:** `kustomize/overlays/registry/kustomization.yaml` redirects the `vote`, `worker`,
`result` image refs to `k3d-voting-app-registry.localhost:5000/...`. Edit the port in this file if you use a
non-default `REGISTRY_PORT`.

---

<a name="troubleshooting">

## 10. Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `verify.sh`/`deploy.sh` can't reach the app over HTTPS | `/etc/hosts` not set up (§3). Verify with `getent hosts vote.127.0.0.1.nip.io`. |
| `deploy.sh` hangs at rollout status | A pod is crash-looping: `kubectl get pods`, `kubectl describe pod <pod>`, `kubectl logs <pod>`. |
| `ImagePullBackOff` in import mode | Images weren't imported — re-run `./scripts/build.sh`. In registry mode, confirm `REGISTRY=1` was used consistently. |
| Port 5000 already in use | AirPlay Receiver on macOS. Use `REGISTRY=1 REGISTRY_PORT=5001` (and update the overlay port). |
| `verify.sh` R15 fails on Rancher Desktop | It falls back to `rdctl shell docker ...` automatically; ensure Docker is reachable via `rdctl`. |
| R9 flaky (tally changes) | Postgres readiness has a 30s delay and the result pod needs to reconnect. The script waits; manual runs should too. |
| R8 "no vote queued during worker outage" | The worker wasn't fully scaled to 0 before the POST. The script waits up to 30s for worker pods to disappear. |
| Re-running verify shows stale data | `verify.sh` never resets the `votes` table, so tallies accumulate across runs. Wipe to start clean: `kubectl delete pod voting-app-postgres-0` (PVC keeps data) or delete+recreate the cluster (§12). The **report** file itself is fresh each run.

---

<a name="known-limitations">

## 11. Known Limitations

Script-related caveats to be aware of (see `README.md` §6 for the full gaps list):

| Limitation | Impact |
|------------|--------|
| **No cleanup script** | No `scripts/cleanup.sh` — delete the cluster manually: `k3d cluster delete voting-app` (§12). |
| **verify.sh doesn't check /etc/hosts** | Assumes the nip.io entries exist; won't fail if they're missing. Set them up manually (§3). |
| **deploy.sh doesn't wait for the ingress** | Assumes the ingress controller is already running; doesn't verify ingress pods are ready. |
| **verify.sh not `-e`** | Uses `set -uo pipefail` (no exit-on-error) so all checks run — good, but a failing check doesn't set a non-zero exit code. |
| **POSTGRES_DB mismatch** | Deployments set `PGDATABASE=voting`; the generated `postgres-secret.env` omits `POSTGRES_DB`. Apps use `voting`; `verify.sh` queries `-d voting`. The `votingdb` DB (from the placeholder file) may be empty. Not caught by R1–R17. |
| **verify.sh.bak is stale** | `scripts/verify.sh.bak` is an outdated backup — not executed by any workflow. Safe to delete. |

---

<a name="cleanup">

## 12. Cleanup

Delete the k3d cluster and (optionally) remove the `/etc/hosts` entries when done:

```bash
k3d cluster delete voting-app
# Remove the /etc/hosts lines you added (optional):
sudo sed -i ''.bak '/127.0.0.1 vote.127.0.0.1.nip.io/d; /127.0.0.1 result.127.0.0.1.nip.io/d' /etc/hosts
```

> The `k3d cluster delete` command also removes the cluster-internal registry (if created in registry mode).

---

<a name="quick-reference"></a>

## Quick Reference

| Script | Command |
|--------|---------|
| Build images | `./scripts/build.sh` |
| Deploy (cluster + images + manifests) | `./scripts/deploy.sh` |
| Full automated verification (R1–R17) | `./scripts/verify.sh` → `.workflow/verify.md` |
| Registry mode | `REGISTRY=1 ./scripts/deploy.sh` |
| Cluster status | `kubectl get pods,svc,ingress` |
| Re-run a single check | Copy the snippet from `docs/MANUAL-TESTING-GUIDE.md` |

**Tip:** `deploy.sh` builds automatically, so the normal loop is `deploy.sh` → `verify.sh`. Use `build.sh`
directly only when you've changed app code and want to reload images without re-applying manifests.
