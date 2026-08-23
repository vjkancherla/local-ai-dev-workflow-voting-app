# PLAN-001: Checkpointed Validation for Voting App

> Problem: Everything was built at once without verifying anything works.
> Solution: Break into sequential checkpoints, each validated before moving forward.

## ✅ COMPLETED — 2026-08-22

All 17 requirements verified passing:

| Req | Description | Status |
|-----|-------------|--------|
| R1 | Vote page renders with both options | ✅ PASS |
| R2 | Casting a vote enqueues to Redis | ✅ PASS |
| R3 | Re-vote is idempotent | ✅ PASS |
| R4 | Vote replay is idempotent | ✅ PASS |
| R5 | Results page shows percentages | ✅ PASS |
| R6 | New vote appears in results within 5s | ✅ PASS |
| R7 | DB schema correct | ✅ PASS |
| R8 | Queued votes survive worker restart | ✅ PASS |
| R9 | Tally survives postgres restart | ✅ PASS |
| R10 | All 5 workloads have probes | ✅ PASS |
| R11 | All 5 have resource requests+limits | ✅ PASS |
| R12 | Kustomize base + registry override | ✅ PASS |
| R13 | HTTPS ingress working | ✅ PASS |
| R14 | No NodePort services | ✅ PASS |
| R15 | arm64 images, no ImagePullBackOff | ✅ PASS |
| R16 | All services healthy | ✅ PASS |
| R17 | Secrets-based credentials | ✅ PASS |

### Key Fixes Applied During Validation

1. **Ingress class**: Changed from `nginx` to `traefik` (k3d default)
2. **Image delivery**: Docker save/load into Rancher Desktop Lima VM → k3d node containerd
3. **Worker termination wait**: Explicit pod deletion loop (not just rollout status)
4. **Postgres readiness wait**: Wait for Ready condition (not just pg_isready) + wait for result pod
5. **Liveness probe delays**: Increased from 5s to 30s to allow postgres connection startup
6. **Docker inspect fallback**: Added rdctl shell for Rancher Desktop compatibility
7. **Result service crash loop**: Fixed by longer liveness probe delay

## Checkpoint Strategy

Each checkpoint must **pass all its checks** before proceeding. If a checkpoint fails, fix it before moving on. This prevents cascading failures where a broken foundation makes later checks ambiguous.

---

## Checkpoint 0: Prerequisites & Environment

**Goal**: Ensure all tooling exists and is compatible.

### Checks
1. `docker --version` — Docker Desktop running, arm64 support
2. `k3d version` — k3d installed
3. `kubectl version --client` — kubectl installed
4. `helm version` — helm installed (for template inspection)
5. `python3 --version` — Python 3.12+ available
6. `openssl version` — for secret generation
7. Check port 5000 availability: `lsof -i :5000` (AirPlay conflict on macOS)

### Gate
All commands return expected versions. If port 5000 is occupied, note REGISTRY_PORT=5001.

---

## Checkpoint 1: Application Code Correctness (No Cluster)

**Goal**: Verify all 3 service codebases are syntactically valid and structurally correct.

### Checks
1. **Syntax check** — `python3 -m py_compile vote/app.py && python3 -m py_compile worker/app.py && python3 -m py_compile result/app.py`
2. **Dockerfile syntax** — `docker build --platform linux/arm64 -t test-vote -f vote/Dockerfile vote/` (dry-run: tag only, no push)
3. **Dockerfile syntax** — same for worker/ and result/
4. **Synthesis decisions verified**:
   - vote/app.py uses `rpush` (not `lpush`) ✓
   - worker/app.py has no Flask import, no gunicorn, uses `blpop` ✓
   - worker/Dockerfile has no gunicorn/flask in requirements ✓
   - result/app.py queries postgres for counts ✓
5. **Template files exist**: vote/templates/index.html, result/templates/result.html

### Gate
All 3 Python files compile. All 3 Dockerfiles build successfully (images in local docker).

---

## Checkpoint 2: Docker Images & Local Registry

**Goal**: Build images and verify they run locally.

### Checks
1. Build vote image: `docker build --platform linux/arm64 -t vote:latest -f vote/Dockerfile .`
2. Build worker image: `docker build --platform linux/arm64 -t worker:latest -f worker/Dockerfile .`
3. Build result image: `docker build --platform linux/arm64 -t result:latest -f result/Dockerfile .`
4. Verify arm64: `docker inspect vote:latest | jq .[0].Architecture` → "arm64"
5. Verify worker runs: `docker run --rm vote:latest python app.py --help` (or similar)
6. Verify worker healthcheck: `docker run -d --name test-worker -e REDIS_URL=redis://redis:6379 -e PGHOST=postgres -e PGDATABASE=voting -e PGUSER=postgres -e PGPASSWORD=test worker:latest` → exits with 0 healthcheck

### Gate
All 3 images build. Architecture confirmed arm64. Worker container starts and exits cleanly.

---

## Checkpoint 3: k3d Cluster Creation

**Goal**: Create the k3d cluster with ingress and verify it's healthy.

### Checks
1. `k3d cluster create voting-app -p "8081:80@loadbalancer" -p "8082:443@loadbalancer" --agents 1`
2. `kubectl cluster-info` → shows k3s running
3. `kubectl get nodes` → 1 node Ready
4. `kubectl get pods -n kube-system` → traefik/nginx-ingress pods Running
5. Add `/etc/hosts`: `127.0.0.1 vote.127.0.0.1.nip.io result.127.0.0.1.nip.io`
6. Verify hosts: `curl -sk --compressed -o /dev/null -w "%{http_code}" https://vote.127.0.0.1.nip.io:8082/` → should return 404 (no app yet)

### Gate
Cluster exists, node Ready, ingress controller pods Running, /etc/hosts configured.

---

## Checkpoint 4: Image Import & Registry Verification

**Goal**: Load images into k3d cluster.

### Checks
1. `k3d image import vote:worker -c voting-app && k3d image import worker:latest -c voting-app && k3d image import result:latest -c voting-app`
2. `docker inspect vote:latest | jq .[0].Architecture` → arm64
3. Verify pull works in-cluster: `kubectl run img-test --image=vote:latest --restart=Never --command -- sleep 5`
4. Wait: `kubectl wait pod/img-test --for=condition=Ready --timeout=30s`
5. `kubectl get pod img-test` → Completed (not ImagePullBackOff)
6. Clean up: `kubectl delete pod img-test`

### Gate
All 3 images imported. Pod runs successfully with imported images. No ImagePullBackOff.

---

## Checkpoint 5: Infrastructure Services (Redis + Postgres)

**Goal**: Deploy Redis and Postgres, verify they become healthy.

### Checks
1. Deploy: `kubectl apply -k kustomize/` (or just the infra: redis + postgres manifests)
2. Wait: `kubectl rollout status deployment/voting-app-redis --timeout=120s`
3. Wait: `kubectl rollout status statefulset/voting-app-postgres --timeout=120s`
4. `kubectl get pods` → redis Running, postgres Running
5. Redis ping: `kubectl exec deploy/voting-app-redis -- redis-cli ping` → PONG
6. Postgres ready: `kubectl exec deploy/postgres-0 -- pg_isready -U postgres` → accepting connections
7. DDL check: `kubectl exec deploy/postgres-0 -- psql -U postgres -d voting -c '\d votes'` → table exists with correct schema

### Gate
Both Redis and Postgres pods Running. Redis responds to PING. Postgres has `votes` table with correct schema.

---

## Checkpoint 6: Application Services (Vote + Worker + Result)

**Goal**: Deploy all 3 app services, verify they become healthy.

### Checks
1. Deploy: `kubectl apply -k kustomize/` (full)
2. Wait: `kubectl rollout status deployment/voting-app-vote --timeout=120s`
3. Wait: `kubectl rollout status deployment/voting-app-worker --timeout=120s`
4. Wait: `kubectl rollout status deployment/voting-app-result --timeout=120s`
5. `kubectl get pods` → all 5 workloads Running (not Pending/Error)
6. Check logs: `kubectl logs deploy/voting-app-worker` → no errors, "shutdown complete" or "BLPOP" messages
7. Check logs: `kubectl logs deploy/voting-app-vote` → gunicorn started
8. Check logs: `kubectl logs deploy/voting-app-result` → gunicorn started

### Gate
All 5 pods Running. No CrashLoopBackOff. Worker logs show BLPOP loop active.

---

## Checkpoint 7: Individual Service Health

**Goal**: Verify each service responds correctly at `/healthz`.

### Checks
1. Vote healthz: `curl -sk --compressed -o /dev/null -w "%{http_code}" https://vote.127.0.0.1.nip.io:8082/healthz` → 200
2. Result healthz: `curl -sk --compressed -o /dev/null -w "%{http_code}" https://result.127.0.0.1.nip.io:8082/healthz` → 200
3. Worker healthz: `kubectl exec deploy/voting-app-worker -- python /app/app.py --healthcheck` → exit 0
4. Redis healthz: `kubectl exec deploy/voting-app-redis -- redis-cli ping` → PONG
5. Postgres healthz: `kubectl exec deploy/postgres-0 -- pg_isready -U postgres` → accepting connections

### Gate
All 5 services report healthy (200 or PONG or exit 0).

---

## Checkpoint 8: End-to-End Voting Flow (R1–R6)

**Goal**: Verify the complete voting pipeline works.

### Checks
1. **R1** — GET / returns 200 with exactly 2 option buttons
2. **R2** — POST /vote enqueues to Redis (scale worker to 0, vote, check LLEN increases)
3. **R3** — Re-vote with same cookie → tally unchanged (count rows before and after)
4. **R4** — Replay same queue entry → one row in postgres (ON CONFLICT upsert)
5. **R5** — Result page shows counts and percentages for both options
6. **R6** — New vote appears in results within 5 seconds

### Gate
All R1–R6 pass. Detailed output captured.

---

## Checkpoint 9: Resilience (R8–R9)

**Goal**: Verify queue survival and data persistence.

### Checks
1. **R8** — Stop worker, vote (goes to queue), restart worker → vote drains to postgres
2. **R9** — Delete postgres pod, wait ready → tally unchanged (PVC preserved)

### Gate
Both R8 and R9 pass. Queue drains after worker restart. Tally survives postgres restart.

---

## Checkpoint 10: Platform Requirements (R10–R17)

**Goal**: Verify all platform-level requirements.

### Checks
1. **R10** — All 5 workloads have liveness AND readiness probes (kubectl get deploy/statefulset -o json | jq)
2. **R11** — All 5 have resource requests AND limits
3. **R12** — Single kustomize config; registry overlay works (`kubectl kustomize kustomize/overlays/registry`)
4. **R13** — Both vote and result return 200 via ingress
5. **R14** — No NodePort services (0 NodePort in kubectl get svc)
6. **R15** — Images are arm64, refs point to local registry (or imported)
7. **R16** — All services expose /healthz reporting dependency status
8. **R17** — Postgres credentials from Secret, no literal password in manifests

### Gate
All R10–R17 pass.

---

## Checkpoint 11: Full Verification Script

**Goal**: Run the complete verify.sh script for final sign-off.

### Checks
1. `bash scripts/verify.sh` → All R1–R17 PASS
2. Review `.workflow/verify.md` output
3. Zero failures

### Gate
Full verification passes with zero failures.

---

## Rollback Plan

If a checkpoint fails:
1. **Checkpoint 1-2** (code/images): Fix app code or Dockerfile, re-test locally
2. **Checkpoint 3-4** (cluster/images): `k3d cluster delete voting-app`, start fresh
3. **Checkpoint 5** (infra): `kubectl delete -k kustomize/`, check logs for initContainer errors
4. **Checkpoint 6** (apps): `kubectl logs deploy/<name>` for each failing pod, fix manifests
5. **Checkpoint 7-11** (functional): Use verify.sh output to pinpoint failures, fix iteratively

Each rollback may require `k3d cluster delete voting-app` for a clean slate.

---

## Checkpoint Completion Log

| Checkpoint | Status | Notes |
|------------|--------|-------|
| 0 | ✅ PASS | Docker 29.5.3, k3d v5.9.0, kubectl v1.36.3, Python 3.14.6 |
| 1 | ✅ PASS | All Python files compile, Dockerfiles build arm64, synthesis decisions verified |
| 2 | ✅ PASS | All 3 images build, arm64 confirmed, worker container starts |
| 3 | ✅ PASS | k3d cluster 'voting-app' created with Traefik ingress |
| 4 | ✅ PASS | Images imported via docker save/load (Rancher Desktop workaround) |
| 5 | ✅ PASS | Redis PONG, Postgres accepting connections, DDL executed |
| 6 | ✅ PASS | All 5 workloads Running |
| 7 | ✅ PASS | All health endpoints 200, worker healthcheck exit 0 |
| 8 | ✅ PASS | R1-R6 pass (voting flow, idempotency, results) |
| 9 | ✅ PASS | R7-R9 pass (schema, queue drain, data survival) |
| 10 | ✅ PASS | R10-R14 pass (probes, resources, kustomize, ingress, no NodePort) |
| 11 | ✅ PASS | R15-R17 pass (arm64, dependencies, secrets) — **ALL 17 PASS** |

---

## Execution Order

```
Checkpoint 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11
```

Each checkpoint is a natural stopping point. The operator can pause, review, or debug at any checkpoint.

**Status**: ✅ ALL CHECKPOINTS COMPLETE — 17/17 requirements verified passing.
