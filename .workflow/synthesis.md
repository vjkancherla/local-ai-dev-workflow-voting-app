# Hyperplan Synthesis — Voting App Implementation

> 5-member adversarial planning session + simplicity auditor review. Consensus findings, split decisions, auditor overrides, and implementation reference.

## Sources

- `.workflow/design.md` (260 lines) — 5-workload architecture, 17 requirements
- `.workflow/requirements.md` (40 lines) — 17 verifiable requirements across Functional/Data/Platform
- `.workflow/implementation-research.md` (599 lines) — Concrete Dockerfiles, Helm patterns, k3d workflow, verification
- **Simplicity auditor review** — 11 findings, 3 architectural overrides (see #9, #10, #11, and Split Decision #6 override)

## Current State

Greenfield — NO implementation code exists. Only design and requirements documents.

## Consensus Findings (3+ of 5 analysts agree)

### #1 [CRITICAL] LPUSH+LPOP = LIFO, not FIFO

- Design says "FIFO between vote and worker" but LPUSH+LPOP creates LIFO (stack)
- Re-votes: user's EARLIER vote overwrites later vote (processed last, wins)
- Implementation Researcher confirmed bug in their own code (vote/app.py uses r.lpush())
- **FIX**: Change `r.lpush("votes", ...)` to `r.rpush("votes", ...)`. RPUSH+LPOP = true FIFO. One line.
- R3's check ("tally total unchanged") passes — bug invisible to stated verification

### #2 [CRITICAL] Flask SECRET_KEY missing from design

- Design mentions "signed Flask session cookie" but never addresses SECRET_KEY
- Without persistent key: pod restart → new random key → ALL sessions invalid → R3 broken
- **FIX**: SECRET_KEY from env var, Helm generates persistent key stored in K8s Secret (resource-policy: keep)

### #3 [HIGH] LPOP/upsert atomicity gap

- Worker LPOP (destructive) then separate Postgres upsert
- Crash between LPOP and COMMIT = vote permanently lost
- R8 resilience claim false for in-flight votes
- **DECISION**: Document as known limitation. Microsecond window on single-node k3d. Acceptable for MVP. Production would need BLMOVE or Redis Streams.

### #4 [HIGH] k3d registry networking (UPDATED — auditor override)

- **Original plan**: Host `localhost:5000` + cluster `k3d-voting-app-registry.localhost:5000`
- **Auditor finding**: `.local` hostname resolution fragile on macOS arm64; the #1 delivery risk
- **NEW APPROACH**: `k3d image import` as PRIMARY workflow. Build → import directly, no registry. Registry push as documented fallback for iterative dev (avoid full re-import).
  - Primary: `docker build -t vote:latest ./vote && k3d image import vote:latest -c voting-app`
  - Fallback: k3d cluster create with `--registry-create` + `docker push k3d-voting-app-registry.localhost:5000/vote:latest`
- macOS: AirPlay may claim port 5000 — use 5001 if using registry fallback

### #5 [MEDIUM] No gunicorn/WSGI in design

- Flask dev server single-threaded in production
- Resolved: gunicorn for vote and result services only. Worker uses no HTTP server (see #7).

### #6 [HIGH] k3d image import beats registry push — auditor recommendation

- `k3d image import` eliminates the `.local` DNS + registry auth surface entirely
- Images loaded directly into k3d containerd — no push, no pull, no registry
- Integrate into `scripts/build.sh`
- Fallback: if iterative dev needs faster cycle, retain k3d-managed registry as option

### #7 [MEDIUM] Worker doesn't need Flask — auditor recommendation

- Worker's only job: BLPOP from Redis, upsert to Postgres. No HTTP endpoint needed.
- Currently the plan puts Flask + gunicorn on worker purely for `/healthz` HTTP probe
- **NEW**: Worker uses exec probe (e.g., `pg_isready` check or simple `python -c` liveness script). No Flask. No gunicorn. No templates.
- Simplifies worker Dockerfile, drops ~50MB+ image size, removes unnecessary attack surface
- Vote and result services KEEP Flask + gunicorn (they serve real HTTP traffic)

### #8 [MEDIUM] BLPOP replaces LPOP+sleep — auditor recommendation (design override)

- Design specifies `LPOP + sleep(0.1)` polling loop
- **Override**: Use `BLPOP votes 5` — zero-CPU blocking pop with 5-second timeout
- More responsive (instant wake on new vote), simpler code, correct behavior
- Note: BLPOP with timeout still satisfies R5 (idempotent vote) — Redis list ops are atomic

## Split Decisions (Lead Resolved + Auditor Overrides)

### #9 Redis AOF: ~~KEEP~~ → DROP (auditor override)

- ~~Lead decision~~: Keep AOF (appendonly yes, appendfsync everysec) to protect against Redis PROCESS crash
- **Auditor override**: Drop AOF entirely. Reasons:
  - Vote queue is transient — lost votes on pod eviction are acceptable (R8 scope)
  - AOF only protects process crash within same pod, not pod eviction or node failure
  - Adds I/O overhead and complexity with negligible benefit for this use case
  - R8 satisfied by: Redis restart resuming from empty queue is correct behavior
- **Action**: Remove `appendonly yes` from Redis config. Worker handles empty queue gracefully.

### #10 Redis maxmemory-policy: ADD explicitly

- Add `maxmemory-policy noeviction` to Redis config. Document cliff-edge failure at 128Mi limit.
- NOTE: AOF is dropped (see #9), but maxmemory-policy remains needed.

### #11 Timestamp-conditional upsert: ADD guard

```sql
ON CONFLICT DO UPDATE SET ... WHERE votes.updated_at < EXCLUDED.updated_at
```
- One-line SQL, zero cost, prevents stale writes under multi-worker.

### #12 DDL single source: Worker initContainer ONLY

- Remove DDL from result service. Worker initContainer is single source of truth for schema.
- Prevents drift risk. IF NOT EXISTS handles concurrent creation.

### #13 Direct Postgres writes: REJECTED

- Violates R2 (requires "enqueues"), R4 (worker drains queue), R8 (queue survival).
- Queue topology stays per requirements.

## Design Changes to Apply in Implementation

1. `vote/app.py`: `r.rpush()` not `r.lpush()` (Consensus #1)
2. `worker/app.py`: BLPOP instead of LPOP+sleep polling (Consensus #8 — design override)
3. `worker/app.py`: Add WHERE timestamp guard to upsert (Lead #11)
4. `worker/app.py`: Document LPOP/upsert gap as known limitation (Consensus #3)
5. `values.yaml`: Add `secretKey` for persistent Flask SECRET_KEY (Consensus #2)
6. `worker-deployment.yaml`: DDL initContainer on worker ONLY (Lead #12)
7. `redis-deployment.yaml`: Explicit `maxmemory-policy noeviction` config (Lead #10)
8. `values.yaml`: `redis.maxmemory` and `redis.maxmemoryPolicy` configurable (Lead #10)
9. `scripts/build.sh`: Use `k3d image import` as primary; registry push as fallback (Consensus #6)
10. `worker/`: Remove Flask, gunicorn, and templates from worker image (Consensus #7)
11. `worker-deployment.yaml`: Replace HTTP probe with exec probe (Consensus #7)
12. `worker-deployment.yaml`, `result-deployment.yaml`: Add `wait-for-postgres` initContainer (auditor startup ordering)
13. Document: `.local` domain resolution + `/etc/hosts` requirement; image retag flow (postgres, redis); k3d `--port` flag

### Dropped from original plan

- ~~Redis AOF (appendonly yes, appendfsync everysec)~~ — DROPPED per auditor override (#9)
- ~~Worker: Flask + gunicorn for /healthz~~ — REPLACED with exec probes (#7/#11)
- ~~redis-deployment.yaml: AOF config~~ — N/A, AOF dropped

## Implementation Reference

27 files total across 3 phases (~75 min MVP, down from 85 — worker simplification):

### Phase 1 — App Code (11 files, down from 12)

- `vote/Dockerfile`, `vote/requirements.txt`, `vote/app.py`, `vote/templates/index.html`
- `worker/Dockerfile`, `worker/requirements.txt`, `worker/app.py` — **No Flask, no gunicorn, no templates**
- `result/Dockerfile`, `result/requirements.txt`, `result/app.py`, `result/templates/result.html`
- `.gitignore`

### Phase 2 — Helm Chart (14 files)

- `helm/voting-app/Chart.yaml`, `values.yaml`
- `templates/_helpers.tpl`, `postgres-secret.yaml`, `postgres-statefulset.yaml`, `postgres-service.yaml`
- `templates/redis-deployment.yaml`, `redis-service.yaml`
- `templates/vote-deployment.yaml`, `vote-service.yaml`
- `templates/worker-deployment.yaml`
- `templates/result-deployment.yaml`, `result-service.yaml`
- `templates/ingress.yaml`

### Phase 3 — Scripts (4 files)

- `scripts/build.sh` (includes `k3d image import` + registry fallback)
- `scripts/deploy.sh`
- `scripts/verify.sh`
- `.workflow/verify.md`

### Key Implementation Decisions

- Base: `python:3.12-slim` arm64 multi-arch
- WSGI: gunicorn for vote and result only. Worker: no HTTP server, exec probes.
- DDL: initContainer on worker only (Lead #12)
- Postgres Secret: Helm lookup + randAlphaNum, resource-policy: keep
- Ingress: `networking.k8s.io/v1`, `ingressClassName: traefik` (NOT Traefik CRD)
- Probes: HTTP `/healthz` (vote, result), TCP 6379 (redis), exec `pg_isready` (postgres), exec `python -c "import psycopg2; ..."` (worker)
- Redis: Deployment (not StatefulSet), no AOF, no PVC, `maxmemory-policy noeviction`
- Postgres: StatefulSet with 1Gi PVC
- Services: ALL ClusterIP, no NodePort
- Image workflow: `k3d image import` primary; `k3d-voting-app-registry.localhost:5000/<svc>:latest` fallback
- InitContainers: `wait-for-postgres` on worker + result Deployments
- k3d: `k3d cluster create voting-app --registry-create voting-app-registry.localhost:5000 -p "8080:80@loadbalancer" --agents 1`

### Worker Architecture (Revised)

```
worker/app.py (no Flask):
  while True:
      vote = redis.blpop("votes", timeout=5)   # zero-CPU blocking
      if vote:
          upsert_postgres(vote)                 # atomic with WHERE timestamp guard
      # exec probe: pg_isready check for liveness
```

### Verification

Full R1-R17 bash script (verify.sh) with per-requirement curl/kubectl commands.
Output to `.workflow/verify.md`.

## Risk Register

| Risk | Severity | Mitigation |
|------|----------|------------|
| k3d registry networking on macOS arm64 | **HIGH** | `k3d image import` bypasses registry entirely; registry push as documented fallback |
| LPOP/upsert vote loss window | HIGH | Documented as known limitation; single-worker mitigates |
| Redis mem cliff-edge at 128Mi | MEDIUM | Explicit `maxmemory-policy noeviction`; document failure mode |
| psycopg2-binary arm64 wheel | LOW | Fallback to source build with build deps |
| Stale write under multi-worker | LOW | WHERE timestamp guard preemptively added |
| SECRET_KEY rotation on upgrade | LOW | Helm lookup preserves existing Secret |
| k3d registry port conflict (AirPlay) | LOW | `k3d image import` avoids registry; port 5001 fallback documented |
| PostgreSQL startup race (worker/result probes) | LOW | `wait-for-postgres` initContainers added |
