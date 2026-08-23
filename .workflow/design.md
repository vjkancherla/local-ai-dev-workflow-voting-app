# Voting App — Design

> Every decision below is traced to the requirement(s) it serves.
> Out of scope (per requirements.md): Auth, TLS, multi-tenancy, HPA, monitoring, real-time push, migrations framework.

---

## 1. High-level Architecture

```
┌──────────┐      ┌───────┐      ┌──────────┐      ┌──────────┐      ┌──────────┐
│  vote    │─────▸│ redis │─────▸│  worker  │─────▸│ postgres │◂─────│  result  │
│ (Flask)  │      │       │      │ (Python) │      │          │      │ (Flask)  │
└──────────┘      └───────┘      └──────────┘      └──────────┘      └──────────┘
     ▪                ▪               ▪                  ▪                 ▪
     ▪ Service        ▪ Service       ▪ Deployment       ▪ StatefulSet    ▪ Service
     ▪ Ingress        ▪ (cluster)     ▪                  ▪ PV + Secret    ▪ Ingress
```

Five Kubernetes workloads in a single Helm chart (R12). Each is a separate container image built for linux/arm64 from a local registry (R15).

---

## 2. Vote Service (Flask) — R1, R2, R3, R16

### Endpoints

| Method | Path | Purpose | Requirement |
|--------|------|---------|-------------|
| GET | `/` | Render page with exactly two option labels | R1 |
| POST | `/vote` | Accept `choice` form field, enqueue to Redis, set session cookie | R2, R3 |
| GET | `/healthz` | Return 200 if Redis reachable, else non-200 | R16 |

### Session & One-Vote-Per-Browser — R3

- A signed Flask session cookie (`voter_id`) is set on first visit.
- `voter_id` is a UUID generated server-side and stored in the cookie.
- POST `/vote` pushes `{ voter_id, choice, timestamp }` onto a Redis list.
- On re-vote: the same `voter_id` is sent; the worker handles deduplication (idempotent upsert). The vote service does not need to check Redis — it always enqueues (R4 handles idempotency). This keeps the vote service stateless and simple.
- **Simpler alternative considered**: Check Redis for existing vote before enqueueing. Rejected because it adds read coupling to Redis and duplicates the idempotency logic already required in the worker (R4).

### Two Options

Hard-coded or configured via Helm `values.yaml` as `vote.options[0]` and `vote.options[1]` (serves R12 by keeping options configurable without code changes).

---

## 3. Redis — R2, R8

### Role

Pure queue. A single Redis list (`votes`) acts as the FIFO between vote and worker (R2).

### Persistence — R8

- Redis runs with `appendonly yes` and `appendfsync everysec`.
- This ensures queued-but-unprocessed votes survive a worker restart (R8): votes remain in the Redis list until the worker `LPOP`s them.
- Redis is deployed as a simple single-replica Deployment (not StatefulSet) — data is transient queue state, not authoritative. Postgres is the source of truth.

---

## 4. Worker (Python) — R4, R8, R16

### Behaviour

- Runs in a loop: `LPOP` from the Redis `votes` list.
- For each message, upserts into Postgres: `INSERT INTO votes (voter_id, choice, updated_at) VALUES (%s, %s, NOW()) ON CONFLICT (voter_id) DO UPDATE SET choice = EXCLUDED.choice, updated_at = NOW()`.
- This guarantees idempotency per voter (R4): replaying the same queue entry produces one row.
- Sleeps briefly (0.1 s) when the queue is empty to avoid busy-spin.

### Resilience — R8

If the worker is stopped, votes accumulate in Redis. On restart, the worker resumes draining. No votes are lost (R8).

### Health — R16

`/healthz` endpoint checks Postgres and Redis connectivity.

---

## 5. Postgres — R7, R9, R17

### Schema — R7

```sql
CREATE TABLE IF NOT EXISTS votes (
    voter_id   VARCHAR(255) PRIMARY KEY,
    choice     VARCHAR(255) NOT NULL,
    updated_at TIMESTAMP    NOT NULL DEFAULT NOW()
);
```

DDL is executed at worker startup (no migrations framework — in scope per Out of scope). The `result` service also runs this DDL on startup for safety (it reads the table).

### Persistence — R9

- Deployed as a StatefulSet with a PersistentVolumeClaim.
- If the pod is deleted and rescheduled, the PVC is re-attached and the tally survives (R9).

### Credentials — R17

- A Kubernetes Secret holds `POSTGRES_USER` and `POSTGRES_PASSWORD`.
- The Helm chart templates reference `secretKeyRef`; no literal password appears in `values.yaml` or templates (R17).
- The Secret is created by a Helm hook (`pre-install` / `pre-upgrade`) or by the user out-of-band.

---

## 6. Result Service (Flask) — R5, R6, R16

### Endpoints

| Method | Path | Purpose | Requirement |
|--------|------|---------|-------------|
| GET | `/` | Query Postgres, render counts and percentages for both options | R5 |
| GET | `/healthz` | Return 200 if Postgres reachable, else non-200 | R16 |

### Freshness — R6

The result service queries Postgres on every request (simple `SELECT choice, COUNT(*) FROM votes GROUP BY choice`). Because the worker drains the queue quickly and R6 allows up to 5 s, a simple polling approach (browser auto-refreshes every 2 s via meta-refresh or JS) satisfies the latency requirement without needing WebSocket or SSE.

### Display — R5

Rendered as an HTML page showing each option with its count and percentage of total votes.

---

## 7. /healthz Endpoint — R16

Every service (vote, redis, worker, result) exposes `/healthz`:

| Service | Checks | 200 when | Non-200 when |
|---------|--------|----------|--------------|
| vote | Redis `PING` | Pong | Connection refused / timeout |
| worker | Redis `PING` + Postgres `SELECT 1` | Both OK | Either fails |
| result | Postgres `SELECT 1` | OK | Connection refused / timeout |
| redis | (native) | Redis up | Redis down |

The Kubernetes probes (R10) point at `/healthz` for all application workloads.

---

## 8. Kubernetes Probes — R10

| Workload | Liveness | Readiness |
|----------|----------|-----------|
| vote | HTTP GET /healthz, period 10 s | HTTP GET /healthz, period 5 s |
| redis | TCP socket :6379, period 10 s | TCP socket :6379, period 5 s |
| worker | HTTP GET /healthz, period 10 s | HTTP GET /healthz, period 5 s |
| postgres | Exec `pg_isready`, period 10 s | Exec `pg_isready`, period 5 s |
| result | HTTP GET /healthz, period 10 s | HTTP GET /healthz, period 5 s |

All five workloads have both liveness and readiness probes (R10).

---

## 9. Resource Requests & Limits — R11

Every workload specifies `resources.requests` and `resources.limits` for CPU and memory. Defaults are set in `values.yaml` and overridable (R12). Example defaults:

| Workload | CPU req | CPU limit | Mem req | Mem limit |
|----------|---------|-----------|---------|-----------|
| vote | 50m | 200m | 64Mi | 128Mi |
| redis | 50m | 200m | 64Mi | 128Mi |
| worker | 50m | 200m | 64Mi | 128Mi |
| postgres | 100m | 500m | 128Mi | 256Mi |
| result | 50m | 200m | 64Mi | 128Mi |

---

## 10. Networking — R13, R14

### Ingress — R13

- A Traefik `Ingress` resource routes:
  - `vote.local → vote-service:80`
  - `result.local → result-service:80`
- Both are reachable through the k3d loadbalancer port (R13).

### No NodePort — R14

- All Services use `type: ClusterIP`.
- No Service uses `type: NodePort` (R14).

---

## 11. Helm Chart — R12

Single chart with the following structure:

```
helm/
  Chart.yaml
  values.yaml
  templates/
    vote-deployment.yaml
    vote-service.yaml
    result-deployment.yaml
    result-service.yaml
    redis-deployment.yaml
    redis-service.yaml
    worker-deployment.yaml
    postgres-statefulset.yaml
    postgres-service.yaml
    postgres-secret.yaml
    ingress.yaml
```

### values.yaml exposes (R12)

- `replicaCount` per workload
- `image.repository` and `image.tag` per workload
- `resources` per workload
- `vote.options` (the two voting choices)
- `postgres.existingSecret` (name of the K8s Secret for credentials)

`helm template` with overrides must render correctly (R12).

---

## 12. Image Build & Registry — R15

- Each application (vote, worker, result) gets a `Dockerfile` targeting `linux/arm64`.
- Images are built with `docker buildx build --platform linux/arm64` and pushed to the k3d local registry (e.g., `localhost:5000/vote:latest`).
- Helm `values.yaml` image refs point at this registry (R15).
- Redis and Postgres use official arm64 images pulled through the same registry mirror.

---

## 13. Design Simplifications Challenged

| Decision | Simpler alternative considered | Why rejected |
|----------|-------------------------------|--------------|
| Worker idempotency via `ON CONFLICT` upsert | Check Redis for duplicate before enqueue | Adds read coupling; duplicates logic already needed for R4 |
| Result polls Postgres on every request | Cache counts in Redis | Adds complexity; R6 allows 5 s latency which simple polling satisfies |
| Redis as simple Deployment | Redis StatefulSet with PVC | Over-engineering; Redis is a transient queue, Postgres is source of truth |
| Single Helm chart | Separate chart per workload | R12 explicitly requires one chart |

---

## 14. Requirement Traceability Matrix

| Req | Design Section |
|-----|---------------|
| R1 | §2 Vote Service |
| R2 | §2 Vote Service, §3 Redis |
| R3 | §2 Session & One-Vote-Per-Browser |
| R4 | §4 Worker idempotency |
| R5 | §6 Result Service |
| R6 | §6 Freshness |
| R7 | §5 Schema |
| R8 | §3 Redis Persistence, §4 Worker Resilience |
| R9 | §5 Postgres Persistence |
| R10 | §8 Kubernetes Probes |
| R11 | §9 Resource Requests & Limits |
| R12 | §11 Helm Chart |
| R13 | §10 Ingress |
| R14 | §10 No NodePort |
| R15 | §12 Image Build & Registry |
| R16 | §7 /healthz Endpoint |
| R17 | §5 Credentials |