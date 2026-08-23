# Voting App — AI-Built Project Walkthrough

> Manual review guide for an AI-generated distributed voting application.
> Each section walks through one component, notes key design decisions, and flags potential gaps.

> 👉 **Want to test it?** See [`docs/MANUAL-TESTING-GUIDE.md`](docs/MANUAL-TESTING-GUIDE.md) for a step-by-step, human-run walkthrough of all 17 requirements (R1–R17).

> 👉 **Want to build/deploy/verify?** See [`docs/SCRIPTS-GUIDE.md`](docs/SCRIPTS-GUIDE.md) for how the `build.sh`, `deploy.sh`, and `verify.sh` scripts work, their environment variables, common workflows, and troubleshooting.

> 👉 **Want to automate the pipeline?** See [`docs/MAKEFILE-GUIDE.md`](docs/MAKEFILE-GUIDE.md) for the `make` targets (build/deploy/verify/teardown), environment-variable passthrough, common workflows, and troubleshooting.

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Application Services](#application-services)
3. [Kubernetes Infrastructure (Kustomize)](#kubernetes-infrastructure-kustomize)
4. [Build, Deploy & Verify Scripts](#build-deploy-verify-scripts)
   - [Makefile Automation](#makefile-automation)
5. [Workflow Documentation](#workflow-documentation)
6. [Summary of Known Gaps](#summary-of-known-gaps)

---

<a name="project-overview"></a>

## 1. Project Overview

**Architecture:**

```
vote (Flask) → redis (queue) → worker (Python) → postgres ← result (Flask)
```

**Platform:** k3d (lightweight Kubernetes) on macOS arm64, deployed via Kustomize.

**Requirements:** 17 verifiable requirements across 3 categories:
- **Functional (R1–R6):** Voting page, enqueueing, one-vote-per-browser, worker idempotency, results display, freshness within 5s
- **Data (R7–R9):** Schema, queue survival on worker restart, tally survival on Postgres restart
- **Platform (R10–R17):** Liveness/readiness probes on all 5 workloads, resource requests/limits, single deployment config, ingress via nginx/Traefik, no NodePort, arm64 images, `/healthz` endpoints, Postgres credentials from Secret

**Design process:** Requirements → Design → Synthesis (5-member adversarial planning) → Implementation Research → Lessons Log. Two human-directed overrides:
1. Helm → Kustomize
2. Ingress resolution — `nip.io`+`/etc/hosts` → `.localhost` (no external DNS) on k3d's bundled Traefik

---

<a name="application-services"></a>

## 2. Application Services

### 2.1 Vote Service (`vote/`)

| File | Purpose |
|------|---------|
| `app.py` | Flask app with gunicorn. Renders voting page, enqueues votes to Redis |
| `Dockerfile` | `python:3.12-slim`, multi-stage, gunicorn CMD |
| `requirements.txt` | Flask, gunicorn, redis |
| `templates/index.html` | Simple HTML form with two voting buttons |

**Key behaviors:**
- Signed Flask session cookie (`voter_id` UUID) for one-vote-per-browser
- `RPUSH` to Redis (FIFO with worker's `BLPOP`)
- `/healthz` checks Redis connectivity
- Options configurable via `OPTIONS` env var (default: `["Cats", "Dogs"]`)

### 2.2 Worker Service (`worker/`)

| File | Purpose |
|------|---------|
| `app.py` | Python script (no Flask). Drains Redis, upserts Postgres |
| `Dockerfile` | `python:3.12-slim`, plain `python app.py` CMD |
| `requirements.txt` | redis, psycopg2-binary |

**Key behaviors:**
- `BLPOP` from Redis `votes` list (zero-CPU blocking)
- Idempotent upsert: `ON CONFLICT (voter_id) DO UPDATE WHERE updated_at < EXCLUDED.updated_at`
- Exec probes: `python app.py --healthcheck` (checks both Redis and Postgres)
- Graceful shutdown via SIGTERM/SIGINT handlers
- Known limitation: LPOP/upsert atomicity gap — in-flight vote lost if killed between BLPOP and COMMIT

### 2.3 Result Service (`result/`)

| File | Purpose |
|------|---------|
| `app.py` | Flask app with gunicorn. Queries Postgres, renders results |
| `Dockerfile` | `python:3.12-slim`, gunicorn CMD |
| `requirements.txt` | Flask, gunicorn, psycopg2-binary |
| `templates/result.html` | HTML table with counts, percentages, total |

**Key behaviors:**
- Queries Postgres: `SELECT choice, COUNT(*) FROM votes GROUP BY choice`
- Auto-refresh via `<meta http-equiv="refresh" content="2">`
- Retry logic for transient Postgres connection failures
- `/healthz` checks Postgres connectivity
- Handles `UndefinedTable` gracefully (table not yet created during warmup)

### Gaps / Observations

| Area | Note |
|------|------|
| **No HTML escaping** | `index.html` and `result.html` use `{{ option }}` without `| safe` — Flask auto-escapes, so XSS-safe but also means no HTML in option labels |
| **No error pages** | If Postgres is down, result service returns 500 (Flask default) — not a custom error page |
| **Hardcoded options** | Options are env vars with defaults — but both vote and result must agree. No mechanism to sync them |
| **Result page refresh** | Meta refresh is basic — no polling, no SSE, no WebSocket |
| **Worker healthcheck** | Returns 0 if both Redis AND Postgres are up — but the worker can still be processing. A pod could be "ready" while its queue is stuck |

---

<a name="kubernetes-infrastructure-kustomize"></a>

## 3. Kubernetes Infrastructure (Kustomize)

### 3.1 Resource Summary

| Workload | Kind | Replicas | Probes | Key Config |
|----------|------|----------|--------|------------|
| vote | Deployment | 1 | HTTP `/healthz` | SECRET_KEY, REDIS_URL |
| worker | Deployment | 1 | Exec `--healthcheck` | Redis URL, PG credentials |
| result | Deployment | 1 | HTTP `/healthz` | PG credentials, initContainer |
| redis | Deployment | 1 | TCP socket:6379 | `--maxmemory 128mb --noeviction` |
| postgres | StatefulSet | 1 | Exec `pg_isready` | Secret credentials, 1Gi PVC |

All Services use `type: ClusterIP`. No NodePort.

### 3.2 Secrets

Generated via Kustomize `secretGenerator` from `kustomize/postgres-secret.env`:

```
POSTGRES_USER=postgres
POSTGRES_PASSWORD=password123
POSTGRES_DB=votingdb
SECRET_KEY=supersecretkey123
```

Named `voting-app-postgres`, referenced by all deployments via `secretKeyRef`.

### 3.3 Ingress

- `ingressClassName: traefik` (✅ k3d ships with **bundled Traefik** — it handles this resource)
- Rules: `vote.localhost` → vote service, `result.localhost` → result service
- `pathType: ImplementationSpecific`
- Annotations: `traefik.ingress.kubernetes.io/router.entrypoints: web,websecure`
- Hosts resolve natively via the `.localhost` TLD (RFC 6761) → 127.0.0.1; no /etc/hosts or external DNS
- **Ingress controller** — k3d ships with bundled Traefik (`ingressClassName: traefik`), which handles all traffic. No separate nginx ingress controller is installed or needed (`deploy.sh` only runs `kubectl apply -k`).

### 3.4 InitContainers

| Deployment | InitContainer | Purpose |
|------------|---------------|---------|
| worker | `init-db` (postgres:16-alpine) | Wait for Postgres, run `CREATE TABLE IF NOT EXISTS votes` |
| result | `wait-for-postgres` (postgres:16-alpine) | Wait for Postgres to be reachable |

### 3.5 Overlay

`kustomize/overlays/registry/kustomization.yaml` redirects `vote`, `worker`, `result` image refs to `k3d-voting-app-registry.localhost:5000/...` for registry-pull mode.

### Gaps / Observations

| Area | Note |
|------|------|
| **POSTGRES_DB mismatch** | `postgres-secret.env` has `POSTGRES_DB=votingdb` but deployments set `PGDATABASE=voting`. Postgres creates DB as `votingdb` on first init, but apps connect to `voting`. **Worker initContainer connects to `voting` (default postgres DB) — DDL runs there. Result queries `voting`. The actual DB `votingdb` may be empty.** |
| **Ingress controller** | Uses k3d's bundled Traefik (`ingressClassName: traefik`), which matches the `traefik.ingress.kubernetes.io/...` annotations. No separate nginx controller is installed. |
| **Redis no AOF** | Design doc claims AOF persistence, but manifest has no AOF config. Votes survive worker restart (Redis stays up) but **NOT Redis pod restart.** |
| **No initContainer resources** | InitContainers have no resource requests/limits |
| **Hardcoded image tags** | Images are `vote:latest`, `worker:latest`, `result:latest` — no versioning, no digest pinning |
| **Secret name stable** | `generatorOptions.disableNameSuffixHash: true` keeps name stable across applies — good for persistence |

---

<a name="build-deploy-verify-scripts"></a>

## 4. Build, Deploy & Verify Scripts

### 4.1 `scripts/build.sh`

Builds the three application images (`vote`, `worker`, `result`) for `linux/arm64` and loads them into the k3d cluster.

**Two modes:**
- **Default (primary):** `docker build` → `k3d image import` directly into cluster's containerd. No registry, no push, no `.local` DNS.
- **Registry mode (`REGISTRY=1`):** `docker build` → `docker push localhost:5000/...` → deploy uses `overlays/registry` to point image refs at the k3d registry.

**Key details:**
- Builds with `--platform linux/arm64`
- Image names: `vote:latest`, `worker:latest`, `result:latest` (import mode) or `localhost:5000/{svc}:latest` (registry mode)
- Cluster name configurable via `CLUSTER` env var (default: `voting-app`)

### 4.2 `scripts/deploy.sh`

End-to-end deployment script.

**Steps:**
1. Creates k3d cluster if missing: `k3d cluster create voting-app -p "8081:80@loadbalancer" -p "8082:443@loadbalancer" --agents 1` (+ `--registry-create` if `REGISTRY=1`)
2. Calls `build.sh` (passing `REGISTRY` and `REGISTRY_PORT`)
3. Generates `postgres-secret.env` if missing (random hex for password + SECRET_KEY)
4. Applies Kustomize: `kubectl apply -k kustomize/` (or `overlays/registry/` in registry mode)
5. Waits for all workloads to become ready (`kubectl rollout status`)

**Local access:**
The `.localhost` hostnames resolve to `127.0.0.1` natively (RFC 6761) — no `/etc/hosts` entry needed:
```
https://vote.localhost:8082/
https://result.localhost:8082/
```

### 4.3 `scripts/verify.sh`

Full R1–R17 verification script. Outputs to `.workflow/verify.md`.

**What it tests (per requirement):**

| Req | Test |
|-----|------|
| R1 | GET /vote returns 200 with exactly two option buttons |
| R2 | POST /vote with worker scaled to 0 → Redis LLEN increases |
| R3 | Two POSTs with same cookie → `SELECT COUNT(*) FROM votes` unchanged |
| R4 | Vote with worker stopped → restart worker → vote appears in Postgres |
| R5 | GET /result returns 200 with counts and percentages |
| R6 | POST vote, poll result page → appears within 5s |
| R7 | `psql \d votes` matches expected schema |
| R8 | Stop worker, vote (queue), restart worker → vote drains to Postgres |
| R9 | Delete Postgres pod, wait ready → tally unchanged |
| R10 | All 5 workloads have liveness AND readiness probes |
| R11 | All 5 have resource requests AND limits |
| R12 | `kubectl kustomize` + `sed` image override works |
| R13 | HTTPS curl to both ingress hosts returns 200 |
| R14 | `kubectl get svc` → 0 NodePort services |
| R15 | `docker inspect vote:latest` → arm64, no ImagePullBackOff |
| R16 | All `/healthz` endpoints return 200 (or 0 exit for exec probes) |
| R17 | No literal password in committed YAML; Secret exists |

**Key implementation details:**
- Uses `-k` flag on all `curl` calls (self-signed certs)
- Accepts HTTP 302 (Flask `redirect()`) alongside 200 for R2
- Uses `sed`-based image override for R12 (avoids `kubectl kustomize` cycle)
- `_connect_with_retry()` in result/app.py handles rapid polling under verify script
- Results appended to `.workflow/verify.md`

### 4.4 `Makefile` — Automation Wrapper

The root `Makefile` wraps the four scripts above with short targets and forwards their environment
variables, so the whole pipeline runs without memorizing script paths or flags. Full details in
[`docs/MAKEFILE-GUIDE.md`](docs/MAKEFILE-GUIDE.md).

| Target | Runs | Description |
|--------|------|-------------|
| `make help` | — | List all targets |
| `make build` | `scripts/build.sh` | Build + load the 3 images |
| `make deploy` (alias `up`) | `scripts/deploy.sh` | Create cluster, build, apply Kustomize, wait ready |
| `make verify` (alias `test`) | `scripts/verify.sh` | Run R1–R17 → `.workflow/verify.md` |
| `make all` | deploy → verify | The normal build → verify loop |
| `make clean` (alias `down`) | `scripts/cleanup.sh` | Delete deployed resources |
| `make destroy` | `scripts/cleanup.sh` (full) | Delete resources + k3d cluster + secret file |
| `make status` | `kubectl get pods,svc,ingress` | Cluster status |

**Env-var passthrough:** `CLUSTER`, `REGISTRY`, `REGISTRY_PORT`, `DELETE_CLUSTER`, `REMOVE_SECRETS`
are forwarded to the underlying scripts. Pass them either way —
`REGISTRY=1 make deploy` or `make deploy REGISTRY=1`.

**Typical loop:** `make all` (deploy + verify). Use `make build` to reload images after app-code
changes, `make destroy` for a full teardown.


<a name="workflow-documentation"></a>

## 5. Workflow Documentation

### 5.1 `.workflow/requirements.md` (40 lines)

Defines the 17 requirements (R1–R17) organized into:
- **Topology:** vote → redis → worker → postgres → result
- **Functional:** R1–R6 (vote page, enqueue, one-vote-per-browser, idempotent worker, results, freshness)
- **Data:** R7–R9 (schema, queue survival, tally survival)
- **Platform:** R10–R17 (probes, resources, single chart, ingress, no NodePort, arm64, /healthz, secrets)
- **Out of scope:** Auth, TLS, multi-tenancy, HPA, monitoring, real-time push, migrations
- **Definition of done:** Every check passes and is recorded in `.workflow/verify.md`

### 5.2 `.workflow/design.md` (260 lines)

Full architectural design with requirement traceability. Covers:
- High-level architecture diagram
- Vote service endpoints, session handling, options config
- Redis as pure queue (Deployment, no AOF, no PVC)
- Worker behavior (BLPOP, upsert, resilience, health)
- Postgres schema, credentials from Secret, PVC
- Result service polling, freshness, error handling
- Kubernetes probes (HTTP, TCP, exec per workload)
- Resource requests/limits table
- Ingress (Traefik, ClusterIP only)
- Single Helm chart structure (later changed to Kustomize)
- Image build for arm64 from local registry
- Design simplifications challenged (with rationale)
- Requirement traceability matrix (R1→design section)

### 5.3 `.workflow/synthesis.md` (~200 lines)

5-member adversarial planning session output:
- **Consensus Findings:** LPUSH→RPUSH fix, SECRET_KEY persistence, LPOP/upsert gap, k3d image import, gunicorn for HTTP services, worker simplification (no Flask), DDL on worker initContainer, Secret generation pattern, Traefik ingress class, probe types per service, Redis Deployment (not StatefulSet)
- **Split Decisions:** AOF dropped, single replica, no HPA, no monitoring, no TLS, no auth
- **Auditor Overrides:** k3d image import over registry push, worker no Flask, DDL on worker initContainer only
- **Implementation Reference:** 27-file breakdown across 3 phases
- **Risk Register:** k3d networking, LPOP gap, Redis mem cliff, psycopg2 arm64, stale writes, SECRET_KEY rotation, port conflicts, Postgres startup race

### 5.4 `.workflow/implementation-research.md` (~600 lines)

Concrete implementation research covering:
- Dockerfile architecture per service (multi-stage, python:3.12-slim, arm64)
- Helm chart patterns (Postgres Secret lookup+randAlphaNum, Traefik Ingress, resource templates, image handling)
- k3d workflow (cluster creation, registry, image import, port mapping)
- Verification script structure (per-requirement tests, output to verify.md)
- File dependency graph and complexity assessment

### 5.5 `.workflow/lessons.md` (61 lines)

Two recorded lessons:
1. **2026-08-12:** Helm → Kustomize switch. Rule: confirm deployment tool with human before generating templates.
2. **2026-08-22:** Ingress resolution — `nip.io`+`/etc/hosts` → `.localhost` (no external DNS) on k3d's bundled Traefik. Resolved macOS port 80/8080 conflicts via host ports 8081/8082. Rule: probe host port availability before selecting ingress ports.

### 5.6 `.ai-docs/PLAN-001-checkpointed-validation.md` (~290 lines)

12-checkpoint validation plan (0–11), each with checks and gates:
- **Checkpoint 0:** Prerequisites & environment
- **Checkpoint 1:** Application code correctness (no cluster)
- **Checkpoint 2:** Docker image builds (no cluster)
- **Checkpoint 3:** k3d cluster creation
- **Checkpoint 4:** Image import into cluster
- **Checkpoint 5:** Infrastructure services (Redis, Postgres, DDL)
- **Checkpoint 6:** Application workloads running
- **Checkpoint 7:** Health endpoints healthy
- **Checkpoint 8:** Functional requirements R1–R6
- **Checkpoint 9:** Data requirements R7–R9
- **Checkpoint 10:** Platform requirements R10–R14
- **Checkpoint 11:** Platform requirements R15–R17 + full verify.sh

<a name="summary-of-known-gaps"></a>

## 6. Summary of Known Gaps

### Critical

| Gap | Impact | Location |
|-----|--------|----------|
| **POSTGRES_DB mismatch** | Apps connect to `voting` but Postgres creates `votingdb` on first init. Worker DDL runs on `voting` (default). Result queries `voting`. | `postgres-secret.env` vs deployment env vars |

### High

| Gap | Impact | Location |
|-----|--------|----------|
| **Redis no AOF** | Design doc claims AOF persistence for R8, but no AOF config in manifest. Votes lost on Redis pod restart. | `redis-deployment.yaml` |
| **Synthesis doc not updated** | References Helm throughout despite Kustomize override. Confusing for future reference. | `.workflow/synthesis.md` |
| **Worker healthcheck too broad** | Returns 0 if both Redis AND Postgres are up, but doesn't check if worker is actively processing. Pod can be "ready" while queue is stuck. | `worker/app.py` healthcheck() |

### Medium

| Gap | Impact | Location |
|------|--------|----------|
| **Ingress class mismatch** | Ingress YAML says `ingressClassName: traefik`, deploy.sh installs nginx. **But k3d ships with bundled Traefik**, so Traefik handles the traffic — ingress works. nginx controller is redundant. | `kustomize/ingress.yaml` vs `deploy.sh` |
| **No initContainer resource limits** | InitContainers can consume unbounded resources during startup. | All initContainers |
| **Hardcoded image tags** | `vote:latest`, `worker:latest`, `result:latest` — no versioning, no digest pinning, no rollback. | All deployment manifests |
| **No cleanup script** | Users must manually run `k3d cluster delete voting-app`. | Missing `scripts/cleanup.sh` |
| **deploy.sh doesn't wait for ingress** | Assumes ingress controller is running; doesn't verify ingress pods are ready. | `deploy.sh` |
| **verify.sh R9 timing** | Deletes Postgres pod, checks tally — PVC re-attach may take time. | `verify.sh` |
| **No HTML escaping control** | Template uses `{{ option }}` — Flask auto-escapes (safe), but no option to render HTML if needed. | `templates/*.html` |

### Low

| Gap | Impact | Location |
|-----|--------|----------|
| **No custom error pages** | If Postgres is down, result returns Flask 500 page. | `result/app.py` |
| **No backup/restore** | No script to backup Postgres data or restore from PVC. | Missing |
| **No CHANGELOG** | No record of changes between versions. | Missing |
| **No CONTRIBUTING guide** | No guidance for contributors. | Missing |
| **verify.sh doesn't verify `.localhost`** | Assumes `.localhost` resolves (it does natively on macOS/Linux); doesn't check before running. | `verify.sh` |
| **Result meta refresh** | Basic auto-refresh, no polling/SSE/WebSocket. | `result/templates/result.html` |

---
- **Status:** All 17 requirements verified passing, all 12 checkpoints complete

### Gaps / Observations

| Area | Note |
|------|------|
| **No `verify.md` file** | Multiple docs reference `.workflow/verify.md` as the output, but the file doesn't exist in the repo (it's generated at runtime by `verify.sh`) |
| **Synthesis says "single Helm chart" but code is Kustomize** | The synthesis doc still references Helm throughout — it wasn't updated after the human override |
| **Implementation research says 27 files but actual count differs** | The research planned 27 files including a Helm chart; actual code has Kustomize manifests instead |
| **No CHANGELOG** | No record of what changed between versions |
| **No CONTRIBUTING guide** | No guidance for contributors on how to add requirements or update docs |

---
### 4.4 `.gitignore`

Ignores: `__pycache__/`, `*.py[cod]`, `.venv/`, `*.log`, `helm/voting-app/charts/`, `kustomize/postgres-secret.env`.

### Gaps / Observations

| Area | Note |
|------|------|
| **verify.sh `set -uo pipefail`** | Uses `-u` (unset vars fail) but NOT `-e` (exit on error). Good — individual checks handle their own errors. |
| `vote.localhost`/`result.localhost` in verify.sh | `VOTE_URL`/`RESULT_URL` default to those hosts; they resolve natively (RFC 6761), so no /etc/hosts setup is required |
| **No cleanup script** | No `scripts/cleanup.sh` to delete the k3d cluster. Users must run `k3d cluster delete voting-app` manually |
| **verify.sh doesn't check R13 ingress controller** | Tests that URLs return 200, but doesn't verify which ingress controller is handling traffic |
| **deploy.sh doesn't verify ingress installation** | Assumes ingress controller is already running — doesn't wait for ingress pods |
| **No idempotent deploy** | `postgres-secret.env` is created once; subsequent runs reuse it. Good. But `k3d cluster create` only runs if cluster doesn't exist — good for idempotency |
| **verify.sh R9 timing** | Deletes Postgres pod and checks tally — but PVC claim may take time to re-attach. Uses `kubectl rollout status` but doesn't verify PVC is bound before querying |
| **No backup/restore** | No script to backup Postgres data or restore from PVC |

---